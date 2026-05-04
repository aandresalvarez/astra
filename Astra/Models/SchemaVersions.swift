import Foundation
import SwiftData

enum ASTRASchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            AgentTask.self,
            TaskRun.self,
            TaskEvent.self,
            Artifact.self,
            Skill.self,
            Connector.self,
            LocalTool.self,
            TaskTemplate.self,
            TaskSchedule.self
        ]
    }

    @Model
    final class Workspace {
        var id: UUID = UUID()
        var name: String = ""
        var primaryPath: String = ""
        var additionalPaths: [String] = []
        var icon: String = "folder"
        var instructions: String = ""
        var lastUsedSkillNames: [String] = []
        var enabledGlobalSkillIDs: [String] = []
        var enabledGlobalConnectorIDs: [String] = []
        var enabledGlobalToolIDs: [String] = []
        var enabledCapabilityIDs: [String] = []
        var memories: [String] = []
        var installedPluginIDs: [String] = []
        var installedPluginVersions: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        @Relationship(deleteRule: .cascade, inverse: \AgentTask.workspace)
        var tasks: [AgentTask] = []

        @Relationship(deleteRule: .cascade, inverse: \Skill.workspace)
        var skills: [Skill] = []

        @Relationship(deleteRule: .cascade, inverse: \Connector.workspace)
        var connectors: [Connector] = []

        @Relationship(deleteRule: .cascade, inverse: \LocalTool.workspace)
        var localTools: [LocalTool] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskTemplate.workspace)
        var templates: [TaskTemplate] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskSchedule.workspace)
        var schedules: [TaskSchedule] = []

        init() {}
    }

    @Model
    final class AgentTask {
        var id: UUID = UUID()
        var title: String = ""
        var goal: String = ""
        var inputs: [String] = []
        var constraints: [String] = []
        var acceptanceCriteria: [String] = []
        var status: TaskStatus = TaskStatus.draft
        var workspace: Workspace?
        var isolationStrategy: IsolationStrategy = IsolationStrategy.sameDirectory
        var validationStrategy: ValidationStrategy = ValidationStrategy.manual
        var tokenBudget: Int = 50000
        var tokensUsed: Int = 0
        var model: String = "claude-sonnet-4-6"
        var testCommand: String = ""
        var costUSD: Double = 0
        var queuePosition: Int = 0
        var sessionId: String?
        var chainedGoal: String = ""
        var chainedFromID: UUID?
        var forkedFromID: UUID?
        var forkedAtRunIndex: Int = 0
        var draftMessages: String = ""
        var maxTurns: Int = 0
        var useAgentTeam: Bool = false
        var teamSize: Int = 3
        var teamInstructions: String = ""
        var templateID: UUID?
        var templateHooksJSON: String = ""
        var originScheduleID: UUID?
        var skillSnapshotsJSON: String = "[]"
        var isPinned: Bool = false
        var isDone: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \TaskRun.task)
        var runs: [TaskRun] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskEvent.task)
        var events: [TaskEvent] = []

        @Relationship(deleteRule: .cascade, inverse: \Artifact.task)
        var artifacts: [Artifact] = []

        @Relationship
        var skills: [Skill] = []

        init() {}
    }

    @Model
    final class TaskRun {
        var id: UUID = UUID()
        var task: AgentTask?
        var status: RunStatus = RunStatus.running
        var startedAt: Date = Date()
        var completedAt: Date?
        var tokensUsed: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var exitCode: Int?
        var output: String = ""
        var costUSD: Double = 0
        var fileChangesJSON: String = "[]"
        var stopReason: String = ""

        init() {}
    }

    @Model
    final class TaskEvent {
        var id: UUID = UUID()
        var task: AgentTask?
        var run: TaskRun?
        var type: String = ""
        var payload: String = ""
        var timestamp: Date = Date()
        var agentName: String?
        var agentId: String?
        var teamName: String?
        var category: String = "lifecycle"

        init() {}
    }

    @Model
    final class Artifact {
        var id: UUID = UUID()
        var task: AgentTask?
        var type: String = ""
        var path: String = ""
        var content: String?
        var version: Int = 1
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class Skill {
        var id: UUID = UUID()
        var name: String = ""
        var skillDescription: String = ""
        var icon: String = "puzzlepiece.extension"
        var allowedTools: [String] = []
        var disallowedTools: [String] = []
        var customTools: [String] = []
        var behaviorInstructions: String = ""
        var environmentKeys: [String] = []
        var environmentValues: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var isGlobal: Bool = false
        var isBuiltIn: Bool = false
        var workspace: Workspace?

        @Relationship(inverse: \AgentTask.skills)
        var tasks: [AgentTask] = []

        @Relationship(inverse: \Connector.skill)
        var connectors: [Connector] = []

        @Relationship(inverse: \LocalTool.skill)
        var localTools: [LocalTool] = []

        init() {}
    }

    @Model
    final class Connector {
        var id: UUID = UUID()
        var name: String = ""
        var serviceType: String = "custom"
        var icon: String = "bolt.horizontal.circle"
        var connectorDescription: String = ""
        var baseURL: String = ""
        var authMethod: String = "none"
        var credentialKeys: [String] = []
        var credentialValues: [String] = []
        var configKeys: [String] = []
        var configValues: [String] = []
        var isGlobal: Bool = false
        var testHTTPMethod: String = "GET"
        var notes: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var skill: Skill?
        var workspace: Workspace?

        init() {}
    }

    @Model
    final class LocalTool {
        var id: UUID = UUID()
        var name: String = ""
        var toolDescription: String = ""
        var icon: String = "terminal"
        var toolType: String = "cli"
        var command: String = ""
        var arguments: String = ""
        var isGlobal: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var skill: Skill?
        var workspace: Workspace?

        init() {}
    }

    @Model
    final class TaskTemplate {
        var id: UUID = UUID()
        var name: String = ""
        var icon: String = "rectangle.3.group"
        var templateDescription: String = ""
        var workspace: Workspace?
        var beforeGoal: String = ""
        var mainGoal: String = ""
        var afterGoal: String = ""
        var beforeBudget: Int = 25000
        var mainBudget: Int = 50000
        var afterBudget: Int = 25000
        var beforeModel: String = "claude-haiku-4-5-20251001"
        var mainModel: String = "claude-sonnet-4-6"
        var afterModel: String = "claude-haiku-4-5-20251001"
        var variablesJSON: String = "[]"
        var hooksJSON: String = "{}"
        var passContextToMain: Bool = true
        var passContextToAfter: Bool = true
        var defaultSkillIDs: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init() {}
    }

    @Model
    final class TaskSchedule {
        var id: UUID = UUID()
        var name: String = ""
        var isEnabled: Bool = true
        var goal: String = ""
        var templateID: UUID?
        var templateVariablesJSON: String = "{}"
        var model: String = "claude-sonnet-4-6"
        var tokenBudget: Int = 50000
        var skillIDs: [String] = []
        var scheduleType: ScheduleType = ScheduleType.once
        var nextFireDate: Date = Date()
        var intervalSeconds: Int = 3600
        var dailyHour: Int = 9
        var dailyMinute: Int = 0
        var weeklyDayOfWeek: Int = 2
        var conversationContext: String = ""
        var resultMode: ScheduleResultMode = ScheduleResultMode.sameThread
        var sourceTaskID: UUID?
        var runResultsJSON: String = "[]"
        var lastFiredAt: Date?
        var fireCount: Int = 0
        var workspace: Workspace?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init() {}
    }
}

enum ASTRASchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            AgentTask.self,
            TaskRun.self,
            TaskEvent.self,
            Artifact.self,
            Skill.self,
            Connector.self,
            LocalTool.self,
            TaskTemplate.self,
            TaskSchedule.self
        ]
    }

    @Model
    final class Workspace {
        var id: UUID = UUID()
        var name: String = ""
        var primaryPath: String = ""
        var additionalPaths: [String] = []
        var icon: String = "folder"
        var instructions: String = ""
        var lastUsedSkillNames: [String] = []
        var enabledGlobalSkillIDs: [String] = []
        var enabledGlobalConnectorIDs: [String] = []
        var enabledGlobalToolIDs: [String] = []
        var enabledCapabilityIDs: [String] = []
        var memories: [String] = []
        var installedPluginIDs: [String] = []
        var installedPluginVersions: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        @Relationship(deleteRule: .cascade, inverse: \AgentTask.workspace)
        var tasks: [AgentTask] = []

        @Relationship(deleteRule: .cascade, inverse: \Skill.workspace)
        var skills: [Skill] = []

        @Relationship(deleteRule: .cascade, inverse: \Connector.workspace)
        var connectors: [Connector] = []

        @Relationship(deleteRule: .cascade, inverse: \LocalTool.workspace)
        var localTools: [LocalTool] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskTemplate.workspace)
        var templates: [TaskTemplate] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskSchedule.workspace)
        var schedules: [TaskSchedule] = []

        init() {}
    }

    @Model
    final class AgentTask {
        var id: UUID = UUID()
        var title: String = ""
        var goal: String = ""
        var inputs: [String] = []
        var constraints: [String] = []
        var acceptanceCriteria: [String] = []
        var status: TaskStatus = TaskStatus.draft
        var workspace: Workspace?
        var isolationStrategy: IsolationStrategy = IsolationStrategy.sameDirectory
        var validationStrategy: ValidationStrategy = ValidationStrategy.manual
        var tokenBudget: Int = 50000
        var tokensUsed: Int = 0
        var model: String = "claude-sonnet-4-6"
        var runtimeID: String? = "claude_code"
        var testCommand: String = ""
        var costUSD: Double = 0
        var queuePosition: Int = 0
        var sessionId: String?
        var chainedGoal: String = ""
        var chainedFromID: UUID?
        var forkedFromID: UUID?
        var forkedAtRunIndex: Int = 0
        var draftMessages: String = ""
        var maxTurns: Int = 0
        var useAgentTeam: Bool = false
        var teamSize: Int = 3
        var teamInstructions: String = ""
        var templateID: UUID?
        var templateHooksJSON: String = ""
        var originScheduleID: UUID?
        var skillSnapshotsJSON: String = "[]"
        var isPinned: Bool = false
        var isDone: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \TaskRun.task)
        var runs: [TaskRun] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskEvent.task)
        var events: [TaskEvent] = []

        @Relationship(deleteRule: .cascade, inverse: \Artifact.task)
        var artifacts: [Artifact] = []

        @Relationship
        var skills: [Skill] = []

        init() {}
    }

    @Model
    final class TaskRun {
        var id: UUID = UUID()
        var task: AgentTask?
        var status: RunStatus = RunStatus.running
        var startedAt: Date = Date()
        var completedAt: Date?
        var tokensUsed: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var runtimeID: String?
        var providerSessionId: String?
        var providerVersion: String?
        var exitCode: Int?
        var output: String = ""
        var costUSD: Double = 0
        var fileChangesJSON: String = "[]"
        var stopReason: String = ""

        init() {}
    }

    @Model
    final class TaskEvent {
        var id: UUID = UUID()
        var task: AgentTask?
        var run: TaskRun?
        var type: String = ""
        var payload: String = ""
        var timestamp: Date = Date()
        var agentName: String?
        var agentId: String?
        var teamName: String?
        var category: String = "lifecycle"

        init() {}
    }

    @Model
    final class Artifact {
        var id: UUID = UUID()
        var task: AgentTask?
        var type: String = ""
        var path: String = ""
        var content: String?
        var version: Int = 1
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class Skill {
        var id: UUID = UUID()
        var name: String = ""
        var skillDescription: String = ""
        var icon: String = "puzzlepiece.extension"
        var allowedTools: [String] = []
        var disallowedTools: [String] = []
        var customTools: [String] = []
        var behaviorInstructions: String = ""
        var environmentKeys: [String] = []
        var environmentValues: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var isGlobal: Bool = false
        var isBuiltIn: Bool = false
        var workspace: Workspace?

        @Relationship(inverse: \AgentTask.skills)
        var tasks: [AgentTask] = []

        @Relationship(inverse: \Connector.skill)
        var connectors: [Connector] = []

        @Relationship(inverse: \LocalTool.skill)
        var localTools: [LocalTool] = []

        init() {}
    }

    @Model
    final class Connector {
        var id: UUID = UUID()
        var name: String = ""
        var serviceType: String = "custom"
        var icon: String = "bolt.horizontal.circle"
        var connectorDescription: String = ""
        var baseURL: String = ""
        var authMethod: String = "none"
        var credentialKeys: [String] = []
        var credentialValues: [String] = []
        var configKeys: [String] = []
        var configValues: [String] = []
        var isGlobal: Bool = false
        var testHTTPMethod: String = "GET"
        var notes: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var skill: Skill?
        var workspace: Workspace?

        init() {}
    }

    @Model
    final class LocalTool {
        var id: UUID = UUID()
        var name: String = ""
        var toolDescription: String = ""
        var icon: String = "terminal"
        var toolType: String = "cli"
        var command: String = ""
        var arguments: String = ""
        var isGlobal: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var skill: Skill?
        var workspace: Workspace?

        init() {}
    }

    @Model
    final class TaskTemplate {
        var id: UUID = UUID()
        var name: String = ""
        var icon: String = "rectangle.3.group"
        var templateDescription: String = ""
        var workspace: Workspace?
        var beforeGoal: String = ""
        var mainGoal: String = ""
        var afterGoal: String = ""
        var beforeBudget: Int = 25000
        var mainBudget: Int = 50000
        var afterBudget: Int = 25000
        var beforeModel: String = "claude-haiku-4-5-20251001"
        var mainModel: String = "claude-sonnet-4-6"
        var afterModel: String = "claude-haiku-4-5-20251001"
        var variablesJSON: String = "[]"
        var hooksJSON: String = "{}"
        var passContextToMain: Bool = true
        var passContextToAfter: Bool = true
        var defaultSkillIDs: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init() {}
    }

    @Model
    final class TaskSchedule {
        var id: UUID = UUID()
        var name: String = ""
        var isEnabled: Bool = true
        var goal: String = ""
        var templateID: UUID?
        var templateVariablesJSON: String = "{}"
        var runtimeID: String? = "claude_code"
        var model: String = "claude-sonnet-4-6"
        var tokenBudget: Int = 50000
        var skillIDs: [String] = []
        var scheduleType: ScheduleType = ScheduleType.once
        var nextFireDate: Date = Date()
        var intervalSeconds: Int = 3600
        var dailyHour: Int = 9
        var dailyMinute: Int = 0
        var weeklyDayOfWeek: Int = 2
        var conversationContext: String = ""
        var resultMode: ScheduleResultMode = ScheduleResultMode.sameThread
        var sourceTaskID: UUID?
        var runResultsJSON: String = "[]"
        var lastFiredAt: Date?
        var fireCount: Int = 0
        var workspace: Workspace?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init() {}
    }
}

enum ASTRASchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            AgentTask.self,
            TaskRun.self,
            TaskEvent.self,
            Artifact.self,
            Skill.self,
            Connector.self,
            LocalTool.self,
            TaskTemplate.self,
            TaskSchedule.self
        ]
    }

    @Model
    final class Workspace {
        var id: UUID = UUID()
        var name: String = ""
        var primaryPath: String = ""
        var additionalPaths: [String] = []
        var icon: String = "folder"
        var instructions: String = ""
        var lastUsedSkillNames: [String] = []
        var enabledGlobalSkillIDs: [String] = []
        var enabledGlobalConnectorIDs: [String] = []
        var enabledGlobalToolIDs: [String] = []
        var enabledCapabilityIDs: [String] = []
        var memories: [String] = []
        var installedPluginIDs: [String] = []
        var installedPluginVersions: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        @Relationship(deleteRule: .cascade, inverse: \AgentTask.workspace)
        var tasks: [AgentTask] = []

        @Relationship(deleteRule: .cascade, inverse: \Skill.workspace)
        var skills: [Skill] = []

        @Relationship(deleteRule: .cascade, inverse: \Connector.workspace)
        var connectors: [Connector] = []

        @Relationship(deleteRule: .cascade, inverse: \LocalTool.workspace)
        var localTools: [LocalTool] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskTemplate.workspace)
        var templates: [TaskTemplate] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskSchedule.workspace)
        var schedules: [TaskSchedule] = []

        init() {}
    }

    @Model
    final class AgentTask {
        var id: UUID = UUID()
        var title: String = ""
        var goal: String = ""
        var inputs: [String] = []
        var constraints: [String] = []
        var acceptanceCriteria: [String] = []
        var status: TaskStatus = TaskStatus.draft
        var workspace: Workspace?
        var isolationStrategy: IsolationStrategy = IsolationStrategy.sameDirectory
        var validationStrategy: ValidationStrategy = ValidationStrategy.manual
        var tokenBudget: Int = 50000
        var tokensUsed: Int = 0
        var model: String = "claude-sonnet-4-6"
        var runtimeID: String? = "claude_code"
        var testCommand: String = ""
        var costUSD: Double = 0
        var queuePosition: Int = 0
        var sessionId: String?
        var chainedGoal: String = ""
        var chainedFromID: UUID?
        var forkedFromID: UUID?
        var forkedAtRunIndex: Int = 0
        var draftMessages: String = ""
        var maxTurns: Int = 0
        var useAgentTeam: Bool = false
        var teamSize: Int = 3
        var teamInstructions: String = ""
        var templateID: UUID?
        var templateHooksJSON: String = ""
        var originScheduleID: UUID?
        var skillSnapshotsJSON: String = "[]"
        var isPinned: Bool = false
        var isDone: Bool = false
        var unreadAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \TaskRun.task)
        var runs: [TaskRun] = []

        @Relationship(deleteRule: .cascade, inverse: \TaskEvent.task)
        var events: [TaskEvent] = []

        @Relationship(deleteRule: .cascade, inverse: \Artifact.task)
        var artifacts: [Artifact] = []

        @Relationship
        var skills: [Skill] = []

        init() {}
    }

    @Model
    final class TaskRun {
        var id: UUID = UUID()
        var task: AgentTask?
        var status: RunStatus = RunStatus.running
        var startedAt: Date = Date()
        var completedAt: Date?
        var tokensUsed: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var runtimeID: String?
        var providerSessionId: String?
        var providerVersion: String?
        var exitCode: Int?
        var output: String = ""
        var costUSD: Double = 0
        var fileChangesJSON: String = "[]"
        var stopReason: String = ""

        init() {}
    }

    @Model
    final class TaskEvent {
        var id: UUID = UUID()
        var task: AgentTask?
        var run: TaskRun?
        var type: String = ""
        var payload: String = ""
        var timestamp: Date = Date()
        var agentName: String?
        var agentId: String?
        var teamName: String?
        var category: String = "lifecycle"

        init() {}
    }

    @Model
    final class Artifact {
        var id: UUID = UUID()
        var task: AgentTask?
        var type: String = ""
        var path: String = ""
        var content: String?
        var version: Int = 1
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class Skill {
        var id: UUID = UUID()
        var name: String = ""
        var skillDescription: String = ""
        var icon: String = "puzzlepiece.extension"
        var allowedTools: [String] = []
        var disallowedTools: [String] = []
        var customTools: [String] = []
        var behaviorInstructions: String = ""
        var environmentKeys: [String] = []
        var environmentValues: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var isGlobal: Bool = false
        var isBuiltIn: Bool = false
        var workspace: Workspace?

        @Relationship(inverse: \AgentTask.skills)
        var tasks: [AgentTask] = []

        @Relationship(inverse: \Connector.skill)
        var connectors: [Connector] = []

        @Relationship(inverse: \LocalTool.skill)
        var localTools: [LocalTool] = []

        init() {}
    }

    @Model
    final class Connector {
        var id: UUID = UUID()
        var name: String = ""
        var serviceType: String = "custom"
        var icon: String = "bolt.horizontal.circle"
        var connectorDescription: String = ""
        var baseURL: String = ""
        var authMethod: String = "none"
        var credentialKeys: [String] = []
        var credentialValues: [String] = []
        var configKeys: [String] = []
        var configValues: [String] = []
        var isGlobal: Bool = false
        var testHTTPMethod: String = "GET"
        var notes: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var skill: Skill?
        var workspace: Workspace?

        init() {}
    }

    @Model
    final class LocalTool {
        var id: UUID = UUID()
        var name: String = ""
        var toolDescription: String = ""
        var icon: String = "terminal"
        var toolType: String = "cli"
        var command: String = ""
        var arguments: String = ""
        var isGlobal: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var skill: Skill?
        var workspace: Workspace?

        init() {}
    }

    @Model
    final class TaskTemplate {
        var id: UUID = UUID()
        var name: String = ""
        var icon: String = "rectangle.3.group"
        var templateDescription: String = ""
        var workspace: Workspace?
        var beforeGoal: String = ""
        var mainGoal: String = ""
        var afterGoal: String = ""
        var beforeBudget: Int = 25000
        var mainBudget: Int = 50000
        var afterBudget: Int = 25000
        var beforeModel: String = "claude-haiku-4-5-20251001"
        var mainModel: String = "claude-sonnet-4-6"
        var afterModel: String = "claude-haiku-4-5-20251001"
        var variablesJSON: String = "[]"
        var hooksJSON: String = "{}"
        var passContextToMain: Bool = true
        var passContextToAfter: Bool = true
        var defaultSkillIDs: [String] = []
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init() {}
    }

    @Model
    final class TaskSchedule {
        var id: UUID = UUID()
        var name: String = ""
        var isEnabled: Bool = true
        var goal: String = ""
        var templateID: UUID?
        var templateVariablesJSON: String = "{}"
        var runtimeID: String? = "claude_code"
        var model: String = "claude-sonnet-4-6"
        var tokenBudget: Int = 50000
        var skillIDs: [String] = []
        var scheduleType: ScheduleType = ScheduleType.once
        var nextFireDate: Date = Date()
        var intervalSeconds: Int = 3600
        var dailyHour: Int = 9
        var dailyMinute: Int = 0
        var weeklyDayOfWeek: Int = 2
        var conversationContext: String = ""
        var resultMode: ScheduleResultMode = ScheduleResultMode.sameThread
        var sourceTaskID: UUID?
        var runResultsJSON: String = "[]"
        var lastFiredAt: Date?
        var fireCount: Int = 0
        var workspace: Workspace?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init() {}
    }
}

enum ASTRASchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            AgentTask.self,
            TaskRun.self,
            TaskEvent.self,
            Artifact.self,
            Skill.self,
            Connector.self,
            LocalTool.self,
            TaskTemplate.self,
            TaskSchedule.self
        ]
    }
}

enum ASTRASchema {
    static var current: Schema {
        Schema(versionedSchema: ASTRASchemaV4.self)
    }
}

enum ASTRAMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ASTRASchemaV1.self, ASTRASchemaV2.self, ASTRASchemaV3.self, ASTRASchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ASTRASchemaV1.self, toVersion: ASTRASchemaV2.self),
            .lightweight(fromVersion: ASTRASchemaV2.self, toVersion: ASTRASchemaV3.self),
            .lightweight(fromVersion: ASTRASchemaV3.self, toVersion: ASTRASchemaV4.self)
        ]
    }
}
