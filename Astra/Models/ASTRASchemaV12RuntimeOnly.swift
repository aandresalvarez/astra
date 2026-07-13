import Foundation
import SwiftData

/// Frozen representation of the runtime-selection-only V12 that briefly
/// existed before the feedback outbox branch merged. This schema is used only
/// by the one-time recovery plan; it must never be edited in place.
public enum ASTRASchemaV12RuntimeOnly: VersionedSchema {
  public static var versionIdentifier = Schema.Version(12, 0, 0)

  @Model
  public final class Workspace {
    public var id: UUID = UUID()
    public var name: String = ""
    public var primaryPath: String = ""
    public var additionalPaths: [String] = []
    public var icon: String = "folder"
    public var instructions: String = ""
    public var lastUsedSkillNames: [String] = []
    public var enabledGlobalSkillIDs: [String] = []
    public var enabledGlobalConnectorIDs: [String] = []
    public var enabledGlobalToolIDs: [String] = []
    public var enabledCapabilityIDs: [String] = []
    public var enabledPackIDs: [String] = []
    public var shelfVisibilityOverrideIDs: [String] = []
    public var shelfVisibilityOverrideValues: [Bool] = []
    public var memories: [String] = []
    public var installedPluginIDs: [String] = []
    public var installedPluginVersions: [String] = []
    public var isStarred: Bool = false
    public var activeWorkingPath: String?
    public var activeExecutionEnvironmentJSON: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \AgentTask.workspace)
    public var tasks: [AgentTask] = []

    @Relationship(deleteRule: .cascade, inverse: \Skill.workspace)
    public var skills: [Skill] = []

    @Relationship(deleteRule: .cascade, inverse: \Connector.workspace)
    public var connectors: [Connector] = []

    @Relationship(deleteRule: .cascade, inverse: \LocalTool.workspace)
    public var localTools: [LocalTool] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskTemplate.workspace)
    public var templates: [TaskTemplate] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskSchedule.workspace)
    public var schedules: [TaskSchedule] = []

    public init() {}
  }

  @Model
  public final class AgentTask {
    public var id: UUID = UUID()
    public var title: String = ""
    public var goal: String = ""
    public var inputs: [String] = []
    public var constraints: [String] = []
    public var acceptanceCriteria: [String] = []
    public var status: TaskStatus = TaskStatus.draft
    public var workspace: Workspace?
    public var isolationStrategy: IsolationStrategy = IsolationStrategy.sameDirectory
    public var validationStrategy: ValidationStrategy = ValidationStrategy.manual
    public var tokenBudget: Int = 50000
    public var tokensUsed: Int = 0
    public var model: String = "claude-sonnet-4-6"
    public var runtimeID: String? = "claude_code"
    public var runtimeExplicitlySelected: Bool = false
    public var testCommand: String = ""
    public var costUSD: Double = 0
    public var queuePosition: Int = 0
    public var sessionId: String?
    public var chainedGoal: String = ""
    public var chainedFromID: UUID?
    public var forkedFromID: UUID?
    public var forkedAtRunIndex: Int = 0
    public var draftMessages: String = ""
    public var maxTurns: Int = 0
    public var useAgentTeam: Bool = false
    public var teamSize: Int = 3
    public var teamInstructions: String = ""
    public var templateID: UUID?
    public var templateHooksJSON: String = ""
    public var originScheduleID: UUID?
    public var skillSnapshotsJSON: String = "[]"
    public var isPinned: Bool = false
    public var isDone: Bool = false
    public var unreadAt: Date?
    public var executionRootPath: String?
    public var executionEnvironmentSnapshotJSON: String?
    public var runtimePermissionOpenRequestsJSON: String? = "[]"
    public var runtimePermissionGrantsJSON: String? = "[]"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var completedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \TaskRun.task)
    public var runs: [TaskRun] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskEvent.task)
    public var events: [TaskEvent] = []

    @Relationship(deleteRule: .cascade, inverse: \Artifact.task)
    public var artifacts: [Artifact] = []

    @Relationship
    public var skills: [Skill] = []

    public init() {}
  }

  @Model
  public final class TaskRun {
    public var id: UUID = UUID()
    public var task: AgentTask?
    public var status: RunStatus = RunStatus.running
    public var startedAt: Date = Date()
    public var completedAt: Date?
    public var tokensUsed: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var runtimeID: String?
    public var providerSessionId: String?
    public var providerVersion: String?
    public var executionEnvironmentSnapshotJSON: String?
    public var providerLaunchSignatureJSON: String?
    public var exitCode: Int?
    public var output: String = ""
    public var costUSD: Double = 0
    public var fileChangesJSON: String = "[]"
    public var stopReason: String = ""

    public init() {}
  }

  @Model
  public final class TaskEvent {
    public var id: UUID = UUID()
    public var task: AgentTask?
    public var run: TaskRun?
    public var type: String = ""
    public var payload: String = ""
    public var timestamp: Date = Date()
    public var agentName: String?
    public var agentId: String?
    public var teamName: String?
    public var category: String = "lifecycle"

    public init() {}
  }

  @Model
  public final class Artifact {
    public var id: UUID = UUID()
    public var task: AgentTask?
    public var type: String = ""
    public var path: String = ""
    public var content: String?
    public var version: Int = 1
    public var createdAt: Date = Date()

    public init() {}
  }

  @Model
  public final class Skill {
    public var id: UUID = UUID()
    public var name: String = ""
    public var skillDescription: String = ""
    public var icon: String = "puzzlepiece.extension"
    public var allowedTools: [String] = []
    public var disallowedTools: [String] = []
    public var customTools: [String] = []
    public var behaviorInstructions: String = ""
    public var environmentKeys: [String] = []
    public var environmentValues: [String] = []
    public var originPackageID: String?
    public var originPackageVersion: String?
    public var originComponentID: String?
    public var originComponentKind: String?
    public var originSourceKind: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var isGlobal: Bool = false
    public var isBuiltIn: Bool = false
    public var workspace: Workspace?

    @Relationship(inverse: \AgentTask.skills)
    public var tasks: [AgentTask] = []

    @Relationship(inverse: \Connector.skill)
    public var connectors: [Connector] = []

    @Relationship(inverse: \LocalTool.skill)
    public var localTools: [LocalTool] = []

    public init() {}
  }

  @Model
  public final class Connector {
    public var id: UUID = UUID()
    public var name: String = ""
    public var serviceType: String = "custom"
    public var icon: String = "bolt.horizontal.circle"
    public var connectorDescription: String = ""
    public var baseURL: String = ""
    public var authMethod: String = "none"
    public var credentialKeys: [String] = []
    public var credentialValues: [String] = []
    public var configKeys: [String] = []
    public var configValues: [String] = []
    public var isGlobal: Bool = false
    public var testHTTPMethod: String = "GET"
    public var notes: String = ""
    public var originPackageID: String?
    public var originPackageVersion: String?
    public var originComponentID: String?
    public var originComponentKind: String?
    public var originSourceKind: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var skill: Skill?
    public var workspace: Workspace?

    public init() {}
  }

  @Model
  public final class LocalTool {
    public var id: UUID = UUID()
    public var name: String = ""
    public var toolDescription: String = ""
    public var icon: String = "terminal"
    public var toolType: String = "cli"
    public var command: String = ""
    public var arguments: String = ""
    public var isGlobal: Bool = false
    public var originPackageID: String?
    public var originPackageVersion: String?
    public var originComponentID: String?
    public var originComponentKind: String?
    public var originSourceKind: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var skill: Skill?
    public var workspace: Workspace?

    public init() {}
  }

  @Model
  public final class TaskTemplate {
    public var id: UUID = UUID()
    public var name: String = ""
    public var icon: String = "rectangle.3.group"
    public var templateDescription: String = ""
    public var workspace: Workspace?
    public var beforeGoal: String = ""
    public var mainGoal: String = ""
    public var afterGoal: String = ""
    public var beforeBudget: Int = 25000
    public var mainBudget: Int = 50000
    public var afterBudget: Int = 25000
    public var beforeModel: String = "claude-haiku-4-5-20251001"
    public var mainModel: String = "claude-sonnet-4-6"
    public var afterModel: String = "claude-haiku-4-5-20251001"
    public var variablesJSON: String = "[]"
    public var hooksJSON: String = "{}"
    public var passContextToMain: Bool = true
    public var passContextToAfter: Bool = true
    public var defaultSkillIDs: [String] = []
    public var originPackageID: String?
    public var originPackageVersion: String?
    public var originComponentID: String?
    public var originComponentKind: String?
    public var originSourceKind: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init() {}
  }

  @Model
  public final class TaskSchedule {
    public var id: UUID = UUID()
    public var name: String = ""
    public var isEnabled: Bool = true
    public var goal: String = ""
    public var templateID: UUID?
    public var templateVariablesJSON: String = "{}"
    public var runtimeID: String? = "claude_code"
    public var model: String = "claude-sonnet-4-6"
    public var tokenBudget: Int = 50000
    public var skillIDs: [String] = []
    public var scheduleType: ScheduleType = ScheduleType.once
    public var nextFireDate: Date = Date()
    public var intervalSeconds: Int = 3600
    public var dailyHour: Int = 9
    public var dailyMinute: Int = 0
    public var weeklyDayOfWeek: Int = 2
    public var conversationContext: String = ""
    public var resultMode: ScheduleResultMode = ScheduleResultMode.sameThread
    public var sourceTaskID: UUID?
    public var runResultsJSON: String = "[]"
    public var lastFiredAt: Date?
    public var fireCount: Int = 0
    public var workspace: Workspace?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init() {}
  }

  @Model
  public final class WorkspaceApp {
    public var id: UUID = UUID()
    public var workspaceID: UUID = UUID()
    public var logicalID: String = ""
    public var name: String = ""
    public var icon: String = "square.grid.2x2"
    public var appDescription: String = ""
    public var lifecycleStatusRaw: String = "draft"
    public var permissionModeRaw: String = "readOnly"
    public var dependencyStatusRaw: String = "unresolved"
    public var manifestRelativePath: String = ""
    public var appDirectoryRelativePath: String = ""
    public var manifestDigest: String = ""
    public var publishedManifestDigest: String = ""
    public var lastKnownGoodManifestDigest: String = ""
    public var latestVersionNumber: Int = 0
    public var sourcePackageID: String?
    public var sourcePackageVersion: String?
    public var sourcePackageDigest: String?
    public var lastOpenedAt: Date?
    public var lastRefreshedAt: Date?
    public var lastRunAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init() {}
  }

  @Model
  public final class WorkspaceAppRun {
    public var id: UUID = UUID()
    public var workspaceID: UUID = UUID()
    public var appID: UUID = UUID()
    public var appLogicalID: String = ""
    public var actionID: String = ""
    public var triggerRaw: String = "user"
    public var statusRaw: String = "running"
    public var startedAt: Date = Date()
    public var completedAt: Date?
    public var inputSummary: String = ""
    public var outputSummary: String = ""
    public var errorMessage: String?
    public var linkedTaskID: UUID?
    public var linkedArtifactPath: String?
    public var pendingActionID: String?
    public var pendingStepIndex: Int = 0
    public var consumedTokens: Int = 0
    public var awaitedTaskIDsJSON: String = "[]"
    public var pendingApprovalActionID: String?

    public init() {}
  }

  @Model
  public final class WorkspaceAppRunEvent {
    public var id: UUID = UUID()
    public var runID: UUID = UUID()
    public var workspaceID: UUID = UUID()
    public var appID: UUID = UUID()
    public var actionID: String = ""
    public var type: String = ""
    public var payload: String = "{}"
    public var timestamp: Date = Date()

    public init() {}
  }

  @Model
  public final class WorkspaceAppDependencyBinding {
    public var id: UUID = UUID()
    public var workspaceID: UUID = UUID()
    public var appID: UUID = UUID()
    public var appLogicalID: String = ""
    public var requirementID: String = ""
    public var contract: String = ""
    public var operationsSummary: String = ""
    public var optional: Bool = false
    public var statusRaw: String = "missingRequired"
    public var implementationID: String?
    public var provider: String?
    public var transportRaw: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init() {}
  }

  @Model
  public final class WorkspaceAppAutomationState {
    public var id: UUID = UUID()
    public var workspaceID: UUID = UUID()
    public var appID: UUID = UUID()
    public var appLogicalID: String = ""
    public var automationID: String = ""
    public var automationType: String = ""
    public var actionID: String?
    public var isEnabled: Bool = false
    public var statusRaw: String = "disabled"
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init() {}
  }

  @Model
  public final class GoogleOAuthAccountProfile {
    public var id: UUID = UUID()
    public var subject: String = ""
    public var email: String = ""
    public var displayName: String = ""
    public var avatarURLString: String?
    public var hostedDomain: String?
    public var grantedScopes: [String] = []
    public var requestedScopes: [String] = []
    public var authStateRaw: String = "active"
    public var authStateReason: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var lastAuthenticatedAt: Date?
    public var revokedAt: Date?

    public init() {}
  }

  public static var models: [any PersistentModel.Type] {
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
      TaskSchedule.self,
      WorkspaceApp.self,
      WorkspaceAppRun.self,
      WorkspaceAppRunEvent.self,
      WorkspaceAppDependencyBinding.self,
      WorkspaceAppAutomationState.self,
      GoogleOAuthAccountProfile.self,
    ]
  }
}
