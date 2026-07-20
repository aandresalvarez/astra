import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Exports and imports workspace configurations as shareable JSON files.
/// SwiftData remains the source of truth. The workspace JSON is a bounded recovery and sharing surface.
///
/// Data safety contract:
/// - UUIDs are exported for every durable entity so names are display text only.
/// - Connector credential values are never exported. Only credential key names are written.
/// - v1-v11 configs remain importable through optional fields and legacy name fallback.
public enum WorkspaceConfigManager {

    // MARK: - Config Schema (v12)

    public static let currentVersion = 12

    private struct WorkspaceAppRunMirrorSnapshot {
        public var runs: [WorkspaceAppRun]
        public var events: [WorkspaceAppRunEvent]
    }

    public enum MirrorLimits {
        public static let maxRunsPerTask = 10
        public static let maxEventsPerTask = 10
        public static let maxWorkspaceAppRuns = 10
        public static let maxWorkspaceAppRunEvents = 10
        public static let maxRunOutputCharacters = 8_000
        public static let maxEventPayloadCharacters = 4_000
        public static let maxWorkspaceAppRunOutputCharacters = 8_000
        public static let maxWorkspaceAppRunEventPayloadCharacters = 4_000
    }

    public enum ScheduleImportTrustPolicy {
        case quarantineEnabledSchedules
        case preserveEnabledState

        public func enabledState(for config: ScheduleConfig) -> Bool {
            switch self {
            case .quarantineEnabledSchedules:
                false
            case .preserveEnabledState:
                config.isEnabled
            }
        }

        public func quarantinedScheduleCount(in schedules: [ScheduleConfig]?) -> Int {
            switch self {
            case .quarantineEnabledSchedules:
                schedules?.filter(\.isEnabled).count ?? 0
            case .preserveEnabledState:
                0
            }
        }
    }

    public struct WorkspaceConfigExportResult {
        public init(status: Status, workspaceID: String, path: String, errorType: String? = nil, errorDomain: String? = nil, errorCode: Int? = nil, errorDescription: String? = nil, parentExists: Bool, parentWritable: Bool) {
            self.status = status
            self.workspaceID = workspaceID
            self.path = path
            self.errorType = errorType
            self.errorDomain = errorDomain
            self.errorCode = errorCode
            self.errorDescription = errorDescription
            self.parentExists = parentExists
            self.parentWritable = parentWritable
        }

        public enum Status: String {
            case exported
            case skippedNoConfig
            case writeFailed
        }

        public var status: Status
        public var workspaceID: String
        public var path: String
        public var errorType: String?
        public var errorDomain: String?
        public var errorCode: Int?
        public var errorDescription: String?
        public var parentExists: Bool
        public var parentWritable: Bool

        public var didExport: Bool {
            status == .exported
        }

        public var auditFields: [String: String] {
            var fields: [String: String] = [
                "workspace_id": workspaceID,
                "config_file": URL(fileURLWithPath: path).lastPathComponent,
                "path": path,
                "result": status.rawValue,
                "parent_exists": String(parentExists),
                "parent_writable": String(parentWritable)
            ]
            if let errorType {
                fields["error_type"] = errorType
            }
            if let errorDomain {
                fields["error_domain"] = errorDomain
            }
            if let errorCode {
                fields["error_code"] = String(errorCode)
            }
            if let errorDescription {
                fields["error_description"] = errorDescription
            }
            return fields
        }
    }

    public struct WorkspaceConfigLoadResult {
        public init(status: Status, path: String, config: WorkspaceConfig? = nil, errorType: String? = nil, errorDomain: String? = nil, errorCode: Int? = nil, errorDescription: String? = nil) {
            self.status = status
            self.path = path
            self.config = config
            self.errorType = errorType
            self.errorDomain = errorDomain
            self.errorCode = errorCode
            self.errorDescription = errorDescription
        }

        public enum Status: String {
            case loaded
            case unreadableFile
            case decodeFailed
        }

        public var status: Status
        public var path: String
        public var config: WorkspaceConfig?
        public var errorType: String?
        public var errorDomain: String?
        public var errorCode: Int?
        public var errorDescription: String?

        public var didLoad: Bool {
            config != nil
        }
    }

    public struct WorkspaceConfigImportResult {
        public init(status: Status, workspace: Workspace, workspaceID: String, skillCount: Int, connectorCount: Int, localToolCount: Int, taskCount: Int, quarantinedScheduleCount: Int, skippedConnectorCount: Int, skippedLocalToolCount: Int) {
            self.status = status
            self.workspace = workspace
            self.workspaceID = workspaceID
            self.skillCount = skillCount
            self.connectorCount = connectorCount
            self.localToolCount = localToolCount
            self.taskCount = taskCount
            self.quarantinedScheduleCount = quarantinedScheduleCount
            self.skippedConnectorCount = skippedConnectorCount
            self.skippedLocalToolCount = skippedLocalToolCount
        }

        public enum Status: String {
            case imported
        }

        public var status: Status
        public var workspace: Workspace
        public var workspaceID: String
        public var skillCount: Int
        public var connectorCount: Int
        public var localToolCount: Int
        public var taskCount: Int
        public var quarantinedScheduleCount: Int
        public var skippedConnectorCount: Int
        public var skippedLocalToolCount: Int

        public var didImport: Bool {
            status == .imported
        }

        public var auditFields: [String: String] {
            [
                "result": status.rawValue,
                "workspace_id": workspaceID,
                "skill_count": String(skillCount),
                "connector_count": String(connectorCount),
                "local_tool_count": String(localToolCount),
                "task_count": String(taskCount),
                "quarantined_schedule_count": String(quarantinedScheduleCount),
                "skipped_connector_count": String(skippedConnectorCount),
                "skipped_local_tool_count": String(skippedLocalToolCount)
            ]
        }
    }

    public struct WorkspaceConfig: Codable, Sendable {
        public init(version: Int = WorkspaceConfigManager.currentVersion, id: String? = nil, name: String, primaryPath: String, additionalPaths: [String], icon: String, instructions: String, isStarred: Bool? = nil, activeWorkingPath: String? = nil, activeExecutionEnvironmentJSON: String? = nil, lastUsedSkillNames: [String]? = nil, enabledGlobalSkillIDs: [String]? = nil, enabledGlobalConnectorIDs: [String]? = nil, enabledGlobalToolIDs: [String]? = nil, enabledCapabilityIDs: [String]? = nil, enabledPackIDs: [String]? = nil, shelfVisibilityOverrides: [String: Bool]? = nil, memories: [String]? = nil, createdAt: Date? = nil, updatedAt: Date? = nil, skills: [SkillConfig], connectors: [ConnectorConfig]? = nil, localTools: [LocalToolConfig]? = nil, templates: [TemplateConfig]? = nil, schedules: [ScheduleConfig]? = nil, sshConnections: [SSHConnection], tasks: [TaskConfig]? = nil, workspaceApps: [WorkspaceAppConfig]? = nil, workspaceAppRuns: [WorkspaceAppRunConfig]? = nil, workspaceAppRunEvents: [WorkspaceAppRunEventConfig]? = nil, workspaceAppDependencyBindings: [WorkspaceAppDependencyBindingConfig]? = nil, workspaceAppAutomationStates: [WorkspaceAppAutomationStateConfig]? = nil, googleOAuthAccountProfiles: [GoogleOAuthAccountProfileConfig]? = nil, installedPlugins: [InstalledPluginRef]? = nil, exportedAt: Date) {
            self.version = version
            self.id = id
            self.name = name
            self.primaryPath = primaryPath
            self.additionalPaths = additionalPaths
            self.icon = icon
            self.instructions = instructions
            self.isStarred = isStarred
            self.activeWorkingPath = activeWorkingPath
            self.activeExecutionEnvironmentJSON = activeExecutionEnvironmentJSON
            self.lastUsedSkillNames = lastUsedSkillNames
            self.enabledGlobalSkillIDs = enabledGlobalSkillIDs
            self.enabledGlobalConnectorIDs = enabledGlobalConnectorIDs
            self.enabledGlobalToolIDs = enabledGlobalToolIDs
            self.enabledCapabilityIDs = enabledCapabilityIDs
            self.enabledPackIDs = enabledPackIDs
            self.shelfVisibilityOverrides = shelfVisibilityOverrides
            self.memories = memories
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.skills = skills
            self.connectors = connectors
            self.localTools = localTools
            self.templates = templates
            self.schedules = schedules
            self.sshConnections = sshConnections
            self.tasks = tasks
            self.workspaceApps = workspaceApps
            self.workspaceAppRuns = workspaceAppRuns
            self.workspaceAppRunEvents = workspaceAppRunEvents
            self.workspaceAppDependencyBindings = workspaceAppDependencyBindings
            self.workspaceAppAutomationStates = workspaceAppAutomationStates
            self.googleOAuthAccountProfiles = googleOAuthAccountProfiles
            self.installedPlugins = installedPlugins
            self.exportedAt = exportedAt
        }

        public var version: Int = WorkspaceConfigManager.currentVersion
        public var id: String?
        public var name: String
        public var primaryPath: String
        public var additionalPaths: [String]
        public var icon: String
        public var instructions: String
        public var isStarred: Bool? = nil
        /// Absolute path of the worktree new chats default to, or nil for the
        /// repository root. Travels with the workspace; it is re-validated on
        /// import and reset to root when the worktree is absent on this machine.
        public var activeWorkingPath: String? = nil
        /// JSON-encoded workspace execution-environment default. Nil means host.
        public var activeExecutionEnvironmentJSON: String? = nil
        public var lastUsedSkillNames: [String]?
        public var enabledGlobalSkillIDs: [String]?
        public var enabledGlobalConnectorIDs: [String]?
        public var enabledGlobalToolIDs: [String]?
        public var enabledCapabilityIDs: [String]?
        public var enabledPackIDs: [String]? = nil
        public var shelfVisibilityOverrides: [String: Bool]? = nil
        public var memories: [String]?
        public var createdAt: Date?
        public var updatedAt: Date?
        public var skills: [SkillConfig]
        public var connectors: [ConnectorConfig]?
        public var localTools: [LocalToolConfig]?
        public var templates: [TemplateConfig]?
        public var schedules: [ScheduleConfig]?
        public var sshConnections: [SSHConnection]
        public var tasks: [TaskConfig]?
        public var workspaceApps: [WorkspaceAppConfig]? = nil
        public var workspaceAppRuns: [WorkspaceAppRunConfig]? = nil
        public var workspaceAppRunEvents: [WorkspaceAppRunEventConfig]? = nil
        public var workspaceAppDependencyBindings: [WorkspaceAppDependencyBindingConfig]? = nil
        public var workspaceAppAutomationStates: [WorkspaceAppAutomationStateConfig]? = nil
        public var googleOAuthAccountProfiles: [GoogleOAuthAccountProfileConfig]? = nil
        public var installedPlugins: [InstalledPluginRef]?
        public var exportedAt: Date
    }

    public struct InstalledPluginRef: Codable, Sendable {
        public init(id: String, version: String, name: String? = nil) {
            self.id = id
            self.version = version
            self.name = name
        }

        public var id: String
        public var version: String
        public var name: String?
    }

    public struct SkillConfig: Codable, Sendable {
        public init(id: String? = nil, name: String, icon: String, description: String, allowedTools: [String], disallowedTools: [String], customTools: [String], behaviorInstructions: String, environmentKeys: [String], environmentValues: [String], isGlobal: Bool? = nil, connectorIDs: [String]? = nil, localToolIDs: [String]? = nil, connectorNames: [String]? = nil, localToolNames: [String]? = nil, originPackageID: String? = nil, originPackageVersion: String? = nil, originComponentID: String? = nil, originComponentKind: String? = nil, originSourceKind: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.icon = icon
            self.description = description
            self.allowedTools = allowedTools
            self.disallowedTools = disallowedTools
            self.customTools = customTools
            self.behaviorInstructions = behaviorInstructions
            self.environmentKeys = environmentKeys
            self.environmentValues = environmentValues
            self.isGlobal = isGlobal
            self.connectorIDs = connectorIDs
            self.localToolIDs = localToolIDs
            self.connectorNames = connectorNames
            self.localToolNames = localToolNames
            self.originPackageID = originPackageID
            self.originPackageVersion = originPackageVersion
            self.originComponentID = originComponentID
            self.originComponentKind = originComponentKind
            self.originSourceKind = originSourceKind
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var name: String
        public var icon: String
        public var description: String
        public var allowedTools: [String]
        public var disallowedTools: [String]
        public var customTools: [String]
        public var behaviorInstructions: String
        public var environmentKeys: [String]
        public var environmentValues: [String]
        public var isGlobal: Bool?
        public var connectorIDs: [String]?
        public var localToolIDs: [String]?
        public var connectorNames: [String]?
        public var localToolNames: [String]?
        public var originPackageID: String? = nil
        public var originPackageVersion: String? = nil
        public var originComponentID: String? = nil
        public var originComponentKind: String? = nil
        public var originSourceKind: String? = nil
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct ConnectorConfig: Codable, Sendable {
        public init(id: String? = nil, name: String, serviceType: String, icon: String, description: String, baseURL: String, authMethod: String, credentialKeys: [String], configKeys: [String], configValues: [String], isGlobal: Bool? = nil, notes: String, originPackageID: String? = nil, originPackageVersion: String? = nil, originComponentID: String? = nil, originComponentKind: String? = nil, originSourceKind: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.serviceType = serviceType
            self.icon = icon
            self.description = description
            self.baseURL = baseURL
            self.authMethod = authMethod
            self.credentialKeys = credentialKeys
            self.configKeys = configKeys
            self.configValues = configValues
            self.isGlobal = isGlobal
            self.notes = notes
            self.originPackageID = originPackageID
            self.originPackageVersion = originPackageVersion
            self.originComponentID = originComponentID
            self.originComponentKind = originComponentKind
            self.originSourceKind = originSourceKind
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var name: String
        public var serviceType: String
        public var icon: String
        public var description: String
        public var baseURL: String
        public var authMethod: String
        public var credentialKeys: [String]
        public var configKeys: [String]
        public var configValues: [String]
        public var isGlobal: Bool?
        public var notes: String
        public var originPackageID: String? = nil
        public var originPackageVersion: String? = nil
        public var originComponentID: String? = nil
        public var originComponentKind: String? = nil
        public var originSourceKind: String? = nil
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct LocalToolConfig: Codable, Sendable {
        public init(id: String? = nil, name: String, description: String, icon: String, toolType: String, command: String, arguments: String, isGlobal: Bool? = nil, originPackageID: String? = nil, originPackageVersion: String? = nil, originComponentID: String? = nil, originComponentKind: String? = nil, originSourceKind: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.description = description
            self.icon = icon
            self.toolType = toolType
            self.command = command
            self.arguments = arguments
            self.isGlobal = isGlobal
            self.originPackageID = originPackageID
            self.originPackageVersion = originPackageVersion
            self.originComponentID = originComponentID
            self.originComponentKind = originComponentKind
            self.originSourceKind = originSourceKind
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var name: String
        public var description: String
        public var icon: String
        public var toolType: String
        public var command: String
        public var arguments: String
        public var isGlobal: Bool?
        public var originPackageID: String? = nil
        public var originPackageVersion: String? = nil
        public var originComponentID: String? = nil
        public var originComponentKind: String? = nil
        public var originSourceKind: String? = nil
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct TemplateConfig: Codable, Sendable {
        public init(id: String? = nil, name: String, icon: String, description: String, beforeGoal: String, mainGoal: String, afterGoal: String, beforeBudget: Int, mainBudget: Int, afterBudget: Int, beforeModel: String, mainModel: String, afterModel: String, variablesJSON: String, hooksJSON: String, passContextToMain: Bool, passContextToAfter: Bool, defaultSkillIDs: [String]? = nil, originPackageID: String? = nil, originPackageVersion: String? = nil, originComponentID: String? = nil, originComponentKind: String? = nil, originSourceKind: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.icon = icon
            self.description = description
            self.beforeGoal = beforeGoal
            self.mainGoal = mainGoal
            self.afterGoal = afterGoal
            self.beforeBudget = beforeBudget
            self.mainBudget = mainBudget
            self.afterBudget = afterBudget
            self.beforeModel = beforeModel
            self.mainModel = mainModel
            self.afterModel = afterModel
            self.variablesJSON = variablesJSON
            self.hooksJSON = hooksJSON
            self.passContextToMain = passContextToMain
            self.passContextToAfter = passContextToAfter
            self.defaultSkillIDs = defaultSkillIDs
            self.originPackageID = originPackageID
            self.originPackageVersion = originPackageVersion
            self.originComponentID = originComponentID
            self.originComponentKind = originComponentKind
            self.originSourceKind = originSourceKind
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var name: String
        public var icon: String
        public var description: String
        public var beforeGoal: String
        public var mainGoal: String
        public var afterGoal: String
        public var beforeBudget: Int
        public var mainBudget: Int
        public var afterBudget: Int
        public var beforeModel: String
        public var mainModel: String
        public var afterModel: String
        public var variablesJSON: String
        public var hooksJSON: String
        public var passContextToMain: Bool
        public var passContextToAfter: Bool
        public var defaultSkillIDs: [String]?
        public var originPackageID: String? = nil
        public var originPackageVersion: String? = nil
        public var originComponentID: String? = nil
        public var originComponentKind: String? = nil
        public var originSourceKind: String? = nil
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct ScheduleConfig: Codable, Sendable {
        public init(id: String? = nil, name: String, isEnabled: Bool, goal: String, routineDescription: String? = nil, routineInstructions: String? = nil, routinePaths: [String]? = nil, templateID: String? = nil, templateVariablesJSON: String, model: String, tokenBudget: Int, scheduleType: String, nextFireDate: Date, intervalSeconds: Int, dailyHour: Int, dailyMinute: Int, weeklyDayOfWeek: Int, fireCount: Int, skillIDs: [String]? = nil, conversationContext: String? = nil, resultMode: String? = nil, sourceTaskID: String? = nil, runResultsJSON: String? = nil, runtimeID: String? = nil, lastFiredAt: Date? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.isEnabled = isEnabled
            self.goal = goal
            self.routineDescription = routineDescription
            self.routineInstructions = routineInstructions
            self.routinePaths = routinePaths
            self.templateID = templateID
            self.templateVariablesJSON = templateVariablesJSON
            self.model = model
            self.tokenBudget = tokenBudget
            self.scheduleType = scheduleType
            self.nextFireDate = nextFireDate
            self.intervalSeconds = intervalSeconds
            self.dailyHour = dailyHour
            self.dailyMinute = dailyMinute
            self.weeklyDayOfWeek = weeklyDayOfWeek
            self.fireCount = fireCount
            self.skillIDs = skillIDs
            self.conversationContext = conversationContext
            self.resultMode = resultMode
            self.sourceTaskID = sourceTaskID
            self.runResultsJSON = runResultsJSON
            self.runtimeID = runtimeID
            self.lastFiredAt = lastFiredAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var name: String
        public var isEnabled: Bool
        public var goal: String
        public var routineDescription: String?
        public var routineInstructions: String?
        public var routinePaths: [String]?
        public var templateID: String?
        public var templateVariablesJSON: String
        public var model: String
        public var tokenBudget: Int
        public var scheduleType: String
        public var nextFireDate: Date
        public var intervalSeconds: Int
        public var dailyHour: Int
        public var dailyMinute: Int
        public var weeklyDayOfWeek: Int
        public var fireCount: Int
        public var skillIDs: [String]?
        public var conversationContext: String?
        public var resultMode: String?
        public var sourceTaskID: String?
        public var runResultsJSON: String?
        public var runtimeID: String?
        public var lastFiredAt: Date?
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct TaskConfig: Codable, Sendable {
        public init(id: String? = nil, title: String, goal: String, status: String, isPinned: Bool? = nil, isDone: Bool? = nil, inputs: [String], constraints: [String], acceptanceCriteria: [String], tokenBudget: Int, tokensUsed: Int, model: String, runtimeID: String? = nil, runtimeExplicitlySelected: Bool? = nil, costUSD: Double, sessionId: String? = nil, maxTurns: Int, createdAt: Date, updatedAt: Date, completedAt: Date? = nil, unreadAt: Date? = nil, isolationStrategy: String? = nil, validationStrategy: String? = nil, testCommand: String? = nil, draftMessages: String? = nil, chainedGoal: String? = nil, chainedFromID: String? = nil, useAgentTeam: Bool? = nil, teamSize: Int? = nil, teamInstructions: String? = nil, templateID: String? = nil, templateHooksJSON: String? = nil, queuePosition: Int? = nil, forkedFromID: String? = nil, forkedAtRunIndex: Int? = nil, originScheduleID: String? = nil, executionRootPath: String? = nil, runs: [RunConfig], events: [EventConfig], artifacts: [ArtifactConfig]? = nil, skillIDs: [String]? = nil, skillNames: [String], skillSnapshots: [SkillSnapshotConfig]? = nil, executionEnvironmentSnapshotJSON: String? = nil, runtimePermissionOpenRequestsJSON: String? = nil, runtimePermissionGrantsJSON: String? = nil, rememberedWorkspaceCanvasItemRawValue: String? = nil, externalOperations: [ExternalOperationConfig]? = nil) {
            self.id = id
            self.title = title
            self.goal = goal
            self.status = status
            self.isPinned = isPinned
            self.isDone = isDone
            self.inputs = inputs
            self.constraints = constraints
            self.acceptanceCriteria = acceptanceCriteria
            self.tokenBudget = tokenBudget
            self.tokensUsed = tokensUsed
            self.model = model
            self.runtimeID = runtimeID
            self.runtimeExplicitlySelected = runtimeExplicitlySelected
            self.costUSD = costUSD
            self.sessionId = sessionId
            self.maxTurns = maxTurns
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.completedAt = completedAt
            self.unreadAt = unreadAt
            self.isolationStrategy = isolationStrategy
            self.validationStrategy = validationStrategy
            self.testCommand = testCommand
            self.draftMessages = draftMessages
            self.chainedGoal = chainedGoal
            self.chainedFromID = chainedFromID
            self.useAgentTeam = useAgentTeam
            self.teamSize = teamSize
            self.teamInstructions = teamInstructions
            self.templateID = templateID
            self.templateHooksJSON = templateHooksJSON
            self.queuePosition = queuePosition
            self.forkedFromID = forkedFromID
            self.forkedAtRunIndex = forkedAtRunIndex
            self.originScheduleID = originScheduleID
            self.executionRootPath = executionRootPath
            self.runs = runs
            self.events = events
            self.artifacts = artifacts
            self.skillIDs = skillIDs
            self.skillNames = skillNames
            self.skillSnapshots = skillSnapshots
            self.executionEnvironmentSnapshotJSON = executionEnvironmentSnapshotJSON
            self.runtimePermissionOpenRequestsJSON = runtimePermissionOpenRequestsJSON
            self.runtimePermissionGrantsJSON = runtimePermissionGrantsJSON
            self.rememberedWorkspaceCanvasItemRawValue = rememberedWorkspaceCanvasItemRawValue
            self.externalOperations = externalOperations
        }

        public var id: String?
        public var title: String
        public var goal: String
        public var status: String
        public var isPinned: Bool?
        public var isDone: Bool?
        public var inputs: [String]
        public var constraints: [String]
        public var acceptanceCriteria: [String]
        public var tokenBudget: Int
        public var tokensUsed: Int
        public var model: String
        public var runtimeID: String?
        public var runtimeExplicitlySelected: Bool?
        public var costUSD: Double
        public var sessionId: String?
        public var maxTurns: Int
        public var createdAt: Date
        public var updatedAt: Date
        public var completedAt: Date?
        public var unreadAt: Date?
        public var isolationStrategy: String?
        public var validationStrategy: String?
        public var testCommand: String?
        public var draftMessages: String?
        public var chainedGoal: String?
        public var chainedFromID: String?
        public var useAgentTeam: Bool?
        public var teamSize: Int?
        public var teamInstructions: String?
        public var templateID: String?
        public var templateHooksJSON: String?
        public var queuePosition: Int? = nil
        public var forkedFromID: String? = nil
        public var forkedAtRunIndex: Int? = nil
        public var originScheduleID: String? = nil
        public var executionRootPath: String? = nil
        public var runs: [RunConfig]
        public var events: [EventConfig]
        public var artifacts: [ArtifactConfig]?
        public var skillIDs: [String]?
        public var skillNames: [String]
        public var skillSnapshots: [SkillSnapshotConfig]?
        public var executionEnvironmentSnapshotJSON: String?
        public var runtimePermissionOpenRequestsJSON: String?
        public var runtimePermissionGrantsJSON: String?
        public var rememberedWorkspaceCanvasItemRawValue: String?
        public var externalOperations: [ExternalOperationConfig]?
    }

    /// Safe workspace-mirror projection. Deliberately excludes commands,
    /// process ids, paths, output, lease ownership, and backend messages.
    public struct ExternalOperationConfig: Codable, Sendable {
        public var id: String?
        public var externalIdentity: String
        public var originatingRunID: String
        public var backendKind: String
        public var backendJobID: String
        public var originatingContextRevision: String?
        public var executionState: String
        public var observationHealth: String
        public var monitoringState: String
        public var nextCheckAt: Date?
        public var generation: Int
        public var createdAt: Date
        public var updatedAt: Date
        /// Launch-time execution-root key: exclusion must survive export/import
        /// even when the workspace's active path changed while the job ran.
        public var launchResourceKey: String? = nil
        /// Delivery acknowledgements: `.completed` alone does not prove a
        /// terminal failure's reasoning wake was delivered — import needs the
        /// keys to distinguish delivered terminal failures from pending ones.
        public var lastNotificationKey: String? = nil
        public var lastWakeKey: String? = nil
    }

    public struct WorkspaceAppConfig: Codable, Sendable {
        public init(id: String? = nil, workspaceID: String, logicalID: String, name: String, icon: String, description: String, lifecycleStatus: String, permissionMode: String, dependencyStatus: String, manifestRelativePath: String, appDirectoryRelativePath: String, manifestDigest: String, publishedManifestDigest: String? = nil, lastKnownGoodManifestDigest: String? = nil, latestVersionNumber: Int? = nil, sourcePackageID: String? = nil, sourcePackageVersion: String? = nil, sourcePackageDigest: String? = nil, lastOpenedAt: Date? = nil, lastRefreshedAt: Date? = nil, lastRunAt: Date? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.workspaceID = workspaceID
            self.logicalID = logicalID
            self.name = name
            self.icon = icon
            self.description = description
            self.lifecycleStatus = lifecycleStatus
            self.permissionMode = permissionMode
            self.dependencyStatus = dependencyStatus
            self.manifestRelativePath = manifestRelativePath
            self.appDirectoryRelativePath = appDirectoryRelativePath
            self.manifestDigest = manifestDigest
            self.publishedManifestDigest = publishedManifestDigest
            self.lastKnownGoodManifestDigest = lastKnownGoodManifestDigest
            self.latestVersionNumber = latestVersionNumber
            self.sourcePackageID = sourcePackageID
            self.sourcePackageVersion = sourcePackageVersion
            self.sourcePackageDigest = sourcePackageDigest
            self.lastOpenedAt = lastOpenedAt
            self.lastRefreshedAt = lastRefreshedAt
            self.lastRunAt = lastRunAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var workspaceID: String
        public var logicalID: String
        public var name: String
        public var icon: String
        public var description: String
        public var lifecycleStatus: String
        public var permissionMode: String
        public var dependencyStatus: String
        public var manifestRelativePath: String
        public var appDirectoryRelativePath: String
        public var manifestDigest: String
        public var publishedManifestDigest: String?
        public var lastKnownGoodManifestDigest: String?
        public var latestVersionNumber: Int?
        public var sourcePackageID: String?
        public var sourcePackageVersion: String?
        public var sourcePackageDigest: String?
        public var lastOpenedAt: Date?
        public var lastRefreshedAt: Date?
        public var lastRunAt: Date?
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct WorkspaceAppRunConfig: Codable, Sendable {
        public init(id: String? = nil, workspaceID: String, appID: String, appLogicalID: String, actionID: String, trigger: String, status: String, startedAt: Date, completedAt: Date? = nil, inputSummary: String, outputSummary: String, errorMessage: String? = nil, linkedTaskID: String? = nil, linkedArtifactPath: String? = nil, pendingActionID: String? = nil, pendingStepIndex: Int? = nil, consumedTokens: Int? = nil, awaitedTaskIDsJSON: String? = nil, pendingApprovalActionID: String? = nil) {
            self.id = id
            self.workspaceID = workspaceID
            self.appID = appID
            self.appLogicalID = appLogicalID
            self.actionID = actionID
            self.trigger = trigger
            self.status = status
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.inputSummary = inputSummary
            self.outputSummary = outputSummary
            self.errorMessage = errorMessage
            self.linkedTaskID = linkedTaskID
            self.linkedArtifactPath = linkedArtifactPath
            self.pendingActionID = pendingActionID
            self.pendingStepIndex = pendingStepIndex
            self.consumedTokens = consumedTokens
            self.awaitedTaskIDsJSON = awaitedTaskIDsJSON
            self.pendingApprovalActionID = pendingApprovalActionID
        }

        public var id: String?
        public var workspaceID: String
        public var appID: String
        public var appLogicalID: String
        public var actionID: String
        public var trigger: String
        public var status: String
        public var startedAt: Date
        public var completedAt: Date?
        public var inputSummary: String
        public var outputSummary: String
        public var errorMessage: String?
        public var linkedTaskID: String?
        public var linkedArtifactPath: String?
        public var pendingActionID: String?
        public var pendingStepIndex: Int?
        public var consumedTokens: Int?
        public var awaitedTaskIDsJSON: String?
        public var pendingApprovalActionID: String?
    }

    public struct WorkspaceAppRunEventConfig: Codable, Sendable {
        public init(id: String? = nil, runID: String, workspaceID: String, appID: String, actionID: String, type: String, payload: String, timestamp: Date) {
            self.id = id
            self.runID = runID
            self.workspaceID = workspaceID
            self.appID = appID
            self.actionID = actionID
            self.type = type
            self.payload = payload
            self.timestamp = timestamp
        }

        public var id: String?
        public var runID: String
        public var workspaceID: String
        public var appID: String
        public var actionID: String
        public var type: String
        public var payload: String
        public var timestamp: Date
    }

    public struct WorkspaceAppDependencyBindingConfig: Codable, Sendable {
        public init(id: String? = nil, workspaceID: String, appID: String, appLogicalID: String, requirementID: String, contract: String, operationsSummary: String, optional: Bool, status: String, implementationID: String? = nil, provider: String? = nil, transport: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.workspaceID = workspaceID
            self.appID = appID
            self.appLogicalID = appLogicalID
            self.requirementID = requirementID
            self.contract = contract
            self.operationsSummary = operationsSummary
            self.optional = optional
            self.status = status
            self.implementationID = implementationID
            self.provider = provider
            self.transport = transport
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var workspaceID: String
        public var appID: String
        public var appLogicalID: String
        public var requirementID: String
        public var contract: String
        public var operationsSummary: String
        public var optional: Bool
        public var status: String
        public var implementationID: String?
        public var provider: String?
        public var transport: String?
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct WorkspaceAppAutomationStateConfig: Codable, Sendable {
        public init(id: String? = nil, workspaceID: String, appID: String, appLogicalID: String, automationID: String, automationType: String, actionID: String? = nil, isEnabled: Bool, status: String, lastRunAt: Date? = nil, nextRunAt: Date? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.workspaceID = workspaceID
            self.appID = appID
            self.appLogicalID = appLogicalID
            self.automationID = automationID
            self.automationType = automationType
            self.actionID = actionID
            self.isEnabled = isEnabled
            self.status = status
            self.lastRunAt = lastRunAt
            self.nextRunAt = nextRunAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var workspaceID: String
        public var appID: String
        public var appLogicalID: String
        public var automationID: String
        public var automationType: String
        public var actionID: String?
        public var isEnabled: Bool
        public var status: String
        public var lastRunAt: Date?
        public var nextRunAt: Date?
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct GoogleOAuthAccountProfileConfig: Codable, Sendable {
        public init(id: String? = nil, subject: String, email: String, displayName: String, avatarURLString: String? = nil, hostedDomain: String? = nil, grantedScopes: [String], requestedScopes: [String], authState: String, authStateReason: String, createdAt: Date, updatedAt: Date, lastAuthenticatedAt: Date? = nil, revokedAt: Date? = nil) {
            self.id = id
            self.subject = subject
            self.email = email
            self.displayName = displayName
            self.avatarURLString = avatarURLString
            self.hostedDomain = hostedDomain
            self.grantedScopes = grantedScopes
            self.requestedScopes = requestedScopes
            self.authState = authState
            self.authStateReason = authStateReason
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.lastAuthenticatedAt = lastAuthenticatedAt
            self.revokedAt = revokedAt
        }

        public var id: String?
        public var subject: String
        public var email: String
        public var displayName: String
        public var avatarURLString: String?
        public var hostedDomain: String?
        public var grantedScopes: [String]
        public var requestedScopes: [String]
        public var authState: String
        public var authStateReason: String
        public var createdAt: Date
        public var updatedAt: Date
        public var lastAuthenticatedAt: Date?
        public var revokedAt: Date?
    }

    public struct RunConfig: Codable, Sendable {
        public init(id: String? = nil, status: String, startedAt: Date, completedAt: Date? = nil, tokensUsed: Int, inputTokens: Int? = nil, outputTokens: Int? = nil, runtimeID: String? = nil, providerSessionId: String? = nil, providerVersion: String? = nil, executionEnvironmentSnapshotJSON: String? = nil, providerLaunchSignatureJSON: String? = nil, exitCode: Int? = nil, output: String, costUSD: Double, stopReason: String, fileChangesJSON: String) {
            self.id = id
            self.status = status
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.tokensUsed = tokensUsed
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.runtimeID = runtimeID
            self.providerSessionId = providerSessionId
            self.providerVersion = providerVersion
            self.executionEnvironmentSnapshotJSON = executionEnvironmentSnapshotJSON
            self.providerLaunchSignatureJSON = providerLaunchSignatureJSON
            self.exitCode = exitCode
            self.output = output
            self.costUSD = costUSD
            self.stopReason = stopReason
            self.fileChangesJSON = fileChangesJSON
        }

        public var id: String?
        public var status: String
        public var startedAt: Date
        public var completedAt: Date?
        public var tokensUsed: Int
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var runtimeID: String?
        public var providerSessionId: String?
        public var providerVersion: String?
        public var executionEnvironmentSnapshotJSON: String?
        public var providerLaunchSignatureJSON: String?
        public var exitCode: Int?
        public var output: String
        public var costUSD: Double
        public var stopReason: String
        public var fileChangesJSON: String
    }

    public struct EventConfig: Codable, Sendable {
        public init(id: String? = nil, type: String, payload: String, timestamp: Date, category: String, agentName: String? = nil, agentId: String? = nil, teamName: String? = nil, runIndex: Int? = nil) {
            self.id = id
            self.type = type
            self.payload = payload
            self.timestamp = timestamp
            self.category = category
            self.agentName = agentName
            self.agentId = agentId
            self.teamName = teamName
            self.runIndex = runIndex
        }

        public var id: String?
        public var type: String
        public var payload: String
        public var timestamp: Date
        public var category: String
        public var agentName: String?
        public var agentId: String?
        public var teamName: String?
        public var runIndex: Int?
    }

    // MARK: - Export

    public static func export(workspace: Workspace) -> WorkspaceConfig? {
        guard let modelContext = workspace.modelContext else {
            return export(workspace: workspace, globalSkills: [])
        }
        return export(workspace: workspace, modelContext: modelContext)
    }

    public static func export(workspace: Workspace, modelContext: ModelContext) -> WorkspaceConfig? {
        let globalSkills = fetchGlobalSkills(modelContext: modelContext)
        let globalConnectors = fetchGlobalConnectors(modelContext: modelContext)
        let globalTools = fetchGlobalTools(modelContext: modelContext)
        return export(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    public static func export(
        workspace: Workspace,
        globalSkills: [Skill],
        globalConnectors: [Connector] = [],
        globalTools: [LocalTool] = []
    ) -> WorkspaceConfig? {
        // Guard against faulted/deleted workspace during dealloc
        guard !workspace.isDeleted, workspace.modelContext != nil else { return nil }

        let skills = skillsForExport(workspace: workspace, globalSkills: globalSkills)
        let connectors = connectorsForExport(
            workspace: workspace,
            skills: skills,
            globalConnectors: globalConnectors
        )
        let localTools = toolsForExport(
            workspace: workspace,
            skills: skills,
            globalTools: globalTools
        )

        let skillConfigs = skills.compactMap(skillConfig)
        let connectorConfigs = connectors.compactMap(connectorConfig)
        let toolConfigs = localTools.compactMap(localToolConfig)
        let templateConfigs = workspace.templates.map(templateConfig)
        let scheduleConfigs = workspace.schedules.map(scheduleConfig)
        let sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
        let operationConfigsByTaskID = externalOperationConfigsForExport(workspace: workspace)
        let taskConfigs = workspace.tasks.map { task in
            taskConfig(task, externalOperations: operationConfigsByTaskID[task.id] ?? [])
        }
        let workspaceAppConfigs = workspaceAppsForExport(workspace: workspace).map(workspaceAppConfig)
        let workspaceAppRunSnapshot = workspaceAppRunMirrorSnapshotForExport(workspace: workspace)
        let workspaceAppRunConfigs = workspaceAppRunSnapshot.runs.map(workspaceAppRunConfig)
        let workspaceAppRunEventConfigs = workspaceAppRunSnapshot.events.map(workspaceAppRunEventConfig)
        let workspaceAppDependencyBindingConfigs = workspaceAppDependencyBindingsForExport(workspace: workspace)
            .map(workspaceAppDependencyBindingConfig)
        let workspaceAppAutomationStateConfigs = workspaceAppAutomationStatesForExport(workspace: workspace)
            .map(workspaceAppAutomationStateConfig)
        let googleOAuthProfileConfigs = googleOAuthProfilesForExport(workspace: workspace).map(googleOAuthAccountProfileConfig)

        var pluginRefs: [InstalledPluginRef] = []
        for (idx, pluginID) in workspace.installedPluginIDs.enumerated() {
            let ver = idx < workspace.installedPluginVersions.count
                ? workspace.installedPluginVersions[idx] : "0.0.0"
            pluginRefs.append(InstalledPluginRef(id: pluginID, version: ver))
        }

        return WorkspaceConfig(
            id: workspace.id.uuidString,
            name: workspace.name,
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths,
            icon: workspace.icon,
            instructions: workspace.instructions,
            isStarred: workspace.isStarred ? true : nil,
            activeWorkingPath: workspace.activeWorkingPath,
            activeExecutionEnvironmentJSON: workspace.activeExecutionEnvironmentJSON,
            lastUsedSkillNames: workspace.lastUsedSkillNames,
            enabledGlobalSkillIDs: workspace.enabledGlobalSkillIDs,
            enabledGlobalConnectorIDs: workspace.enabledGlobalConnectorIDs,
            enabledGlobalToolIDs: workspace.enabledGlobalToolIDs,
            enabledCapabilityIDs: workspace.enabledCapabilityIDs,
            enabledPackIDs: workspace.enabledPackIDs,
            shelfVisibilityOverrides: workspace.shelfVisibilityOverrides,
            memories: workspace.memories,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            skills: skillConfigs,
            connectors: connectorConfigs,
            localTools: toolConfigs,
            templates: templateConfigs,
            schedules: scheduleConfigs,
            sshConnections: sshConnections,
            tasks: taskConfigs,
            workspaceApps: workspaceAppConfigs.isEmpty ? nil : workspaceAppConfigs,
            workspaceAppRuns: workspaceAppRunConfigs.isEmpty ? nil : workspaceAppRunConfigs,
            workspaceAppRunEvents: workspaceAppRunEventConfigs.isEmpty ? nil : workspaceAppRunEventConfigs,
            workspaceAppDependencyBindings: workspaceAppDependencyBindingConfigs.isEmpty ? nil : workspaceAppDependencyBindingConfigs,
            workspaceAppAutomationStates: workspaceAppAutomationStateConfigs.isEmpty ? nil : workspaceAppAutomationStateConfigs,
            googleOAuthAccountProfiles: googleOAuthProfileConfigs.isEmpty ? nil : googleOAuthProfileConfigs,
            installedPlugins: pluginRefs.isEmpty ? nil : pluginRefs,
            exportedAt: Date()
        )
    }

    public static func exportToFile(workspace: Workspace, url: URL) throws {
        guard let config = export(workspace: workspace) else { return }
        try prepareMirrorParentIfNeeded(workspace: workspace, url: url)
        try write(config, to: url)
    }

    public static func exportToFile(workspace: Workspace, modelContext: ModelContext, url: URL) throws {
        guard let config = export(workspace: workspace, modelContext: modelContext) else { return }
        try prepareMirrorParentIfNeeded(workspace: workspace, url: url)
        try write(config, to: url)
    }

    @discardableResult
    public static func exportToFileResult(workspace: Workspace, url: URL) -> WorkspaceConfigExportResult {
        guard let config = export(workspace: workspace) else {
            return exportResult(
                status: .skippedNoConfig,
                workspaceID: workspace.id.uuidString,
                url: url,
                error: nil
            )
        }
        do {
            try prepareMirrorParentIfNeeded(workspace: workspace, url: url)
        } catch {
            return exportResult(status: .writeFailed, workspaceID: workspace.id.uuidString, url: url, error: error)
        }
        return writeResult(config, workspaceID: workspace.id.uuidString, to: url)
    }

    @discardableResult
    public static func exportToFileResult(workspace: Workspace, modelContext: ModelContext, url: URL) -> WorkspaceConfigExportResult {
        guard let config = export(workspace: workspace, modelContext: modelContext) else {
            return exportResult(
                status: .skippedNoConfig,
                workspaceID: workspace.id.uuidString,
                url: url,
                error: nil
            )
        }
        do {
            try prepareMirrorParentIfNeeded(workspace: workspace, url: url)
        } catch {
            return exportResult(status: .writeFailed, workspaceID: workspace.id.uuidString, url: url, error: error)
        }
        return writeResult(config, workspaceID: workspace.id.uuidString, to: url)
    }

    /// Auto-save config to the workspace's primary path for recovery.
    ///
    /// The Sendable `WorkspaceConfig` snapshot is built synchronously here (it must
    /// read SwiftData objects on the current actor), then the JSON encode + atomic
    /// file write are handed to `WorkspaceAutoExportWriter`, which serializes all
    /// auto-export writes off the main actor. This removes the synchronous
    /// `encode(.prettyPrinted)` + `data.write` stall from every `modelContext.save()`
    /// on a live run. The result-returning `exportToFileResult` path (used by tests,
    /// explicit user export, and flush-on-disappear) is intentionally left synchronous.
    public static func autoExport(workspace: Workspace) {
        let target = autoExportTarget(for: workspace.primaryPath)
        guard let url = target.url else {
            logAutoExportSkipped(workspace: workspace, reason: target.reason)
            return
        }
        guard let config = export(workspace: workspace) else { return }
        let workspaceID = workspace.id.uuidString
        Task.detached(priority: .utility) {
            await WorkspaceAutoExportWriter.shared.write(config, to: url, workspaceID: workspaceID)
        }
    }

    public static func autoExport(workspace: Workspace, modelContext: ModelContext) {
        let target = autoExportTarget(for: workspace.primaryPath)
        guard let url = target.url else {
            logAutoExportSkipped(workspace: workspace, reason: target.reason)
            return
        }
        guard let config = export(workspace: workspace, modelContext: modelContext) else { return }
        let workspaceID = workspace.id.uuidString
        Task.detached(priority: .utility) {
            await WorkspaceAutoExportWriter.shared.write(config, to: url, workspaceID: workspaceID)
        }
    }

    public struct AutoExportTarget {
        public let url: URL?
        public let reason: String
    }

    public static func autoExportTarget(for workspacePath: String) -> AutoExportTarget {
        guard !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AutoExportTarget(url: nil, reason: "primary_path_empty")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AutoExportTarget(url: nil, reason: "primary_path_unavailable")
        }

        let configPath = WorkspaceFileLayout.workspaceConfigFile(for: workspacePath)
        guard !configPath.isEmpty else {
            return AutoExportTarget(url: nil, reason: "config_path_empty")
        }
        let supportPath = WorkspaceFileLayout.supportDirectory(for: workspacePath)
        do {
            try FileManager.default.createDirectory(
                atPath: supportPath,
                withIntermediateDirectories: true
            )
            try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspacePath)
        } catch {
            return AutoExportTarget(url: nil, reason: "support_directory_unavailable")
        }

        return AutoExportTarget(url: URL(fileURLWithPath: configPath), reason: "ready")
    }

    private static func logAutoExportSkipped(workspace: Workspace, reason: String) {
        AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
            "result": "auto_export_skipped",
            "reason": reason,
            "workspace_id": workspace.id.uuidString
        ], level: .debug)
    }

    private static func exportResult(
        status: WorkspaceConfigExportResult.Status,
        workspaceID: String,
        url: URL,
        error: Error?
    ) -> WorkspaceConfigExportResult {
        let nsError = error.map { $0 as NSError }
        let parent = url.deletingLastPathComponent()
        return WorkspaceConfigExportResult(
            status: status,
            workspaceID: workspaceID,
            path: url.path,
            errorType: error.map { String(describing: type(of: $0)) },
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: nsError?.localizedDescription,
            parentExists: FileManager.default.fileExists(atPath: parent.path),
            parentWritable: FileManager.default.isWritableFile(atPath: parent.path)
        )
    }

    private static func writeResult(_ config: WorkspaceConfig, workspaceID: String, to url: URL) -> WorkspaceConfigExportResult {
        do {
            try write(config, to: url)
            return exportResult(status: .exported, workspaceID: workspaceID, url: url, error: nil)
        } catch {
            return exportResult(status: .writeFailed, workspaceID: workspaceID, url: url, error: error)
        }
    }

    private static func prepareMirrorParentIfNeeded(workspace: Workspace, url: URL) throws {
        let mirrorURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath))
            .standardizedFileURL
        guard url.standardizedFileURL.path == mirrorURL.path else { return }
        try FileManager.default.createDirectory(
            at: mirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspace.primaryPath)
    }

    // MARK: - Import

    public static func loadConfig(
        from url: URL,
        accessIntent: HostFileAccessIntent = .explicitUserSelection
    ) throws -> WorkspaceConfig {
        let data = try readConfigData(from: url, accessIntent: accessIntent)
        return try workspaceConfigDecoder().decode(WorkspaceConfig.self, from: data)
    }

    public static func loadConfigResult(
        from url: URL,
        accessIntent: HostFileAccessIntent = .explicitUserSelection
    ) -> WorkspaceConfigLoadResult {
        let data: Data
        do {
            data = try readConfigData(from: url, accessIntent: accessIntent)
        } catch {
            return loadResult(status: .unreadableFile, url: url, config: nil, error: error)
        }

        do {
            let config = try workspaceConfigDecoder().decode(WorkspaceConfig.self, from: data)
            return loadResult(status: .loaded, url: url, config: config, error: nil)
        } catch {
            return loadResult(status: .decodeFailed, url: url, config: nil, error: error)
        }
    }

    private static func readConfigData(from url: URL, accessIntent: HostFileAccessIntent) throws -> Data {
        try HostFileAccessBroker().readData(at: url, intent: accessIntent)
    }

    private static func workspaceConfigDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Create a new Workspace + Skills + Connectors + Tools + Templates from a config.
    @MainActor
    public static func importWorkspace(
        from config: WorkspaceConfig,
        modelContext: ModelContext,
        scheduleTrustPolicy: ScheduleImportTrustPolicy = .quarantineEnabledSchedules
    ) -> Workspace {
        importWorkspaceResult(
            from: config,
            modelContext: modelContext,
            scheduleTrustPolicy: scheduleTrustPolicy
        ).workspace
    }

    /// Create a new Workspace + Skills + Connectors + Tools + Templates from a config.
    @MainActor
    public static func importWorkspaceResult(
        from config: WorkspaceConfig,
        modelContext: ModelContext,
        scheduleTrustPolicy: ScheduleImportTrustPolicy = .quarantineEnabledSchedules
    ) -> WorkspaceConfigImportResult {
        let workspace = Workspace(
            name: config.name,
            primaryPath: config.primaryPath,
            additionalPaths: config.additionalPaths,
            icon: config.icon,
            instructions: config.instructions
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            workspace.id = id
        }
        workspace.lastUsedSkillNames = config.lastUsedSkillNames ?? []
        workspace.enabledGlobalSkillIDs = config.enabledGlobalSkillIDs ?? []
        workspace.enabledGlobalConnectorIDs = config.enabledGlobalConnectorIDs ?? []
        workspace.enabledGlobalToolIDs = config.enabledGlobalToolIDs ?? []
        workspace.enabledCapabilityIDs = config.enabledCapabilityIDs ?? []
        workspace.enabledPackIDs = config.enabledPackIDs ?? []
        workspace.shelfVisibilityOverrides = config.shelfVisibilityOverrides ?? [:]
        workspace.memories = config.memories ?? []
        workspace.isStarred = config.isStarred ?? false
        workspace.activeExecutionEnvironmentJSON = sanitizedExecutionEnvironmentJSON(config.activeExecutionEnvironmentJSON)
        workspace.activeWorkingPath = importedActiveWorkingPath(
            config.activeWorkingPath,
            primaryPath: config.primaryPath,
            additionalPaths: config.additionalPaths
        )
        if let refs = config.installedPlugins {
            workspace.installedPluginIDs = refs.map(\.id)
            workspace.installedPluginVersions = refs.map(\.version)
        }
        workspace.createdAt = config.createdAt ?? workspace.createdAt
        workspace.updatedAt = config.updatedAt ?? workspace.updatedAt
        modelContext.insert(workspace)

        var connectorsByID: [String: Connector] = [:]
        var connectorsByName: [String: Connector] = [:]
        var skippedConnectorCount = 0
        for cc in config.connectors ?? [] {
            guard let connector = reusedGlobalConnector(for: cc, modelContext: modelContext) ?? makeConnector(from: cc) else {
                skippedConnectorCount += 1
                continue
            }
            connector.workspace = (connector.isGlobal ? nil : workspace)
            if connector.isGlobal {
                appendUnique(connector.id.uuidString, to: &workspace.enabledGlobalConnectorIDs)
            }
            if connector.modelContext == nil {
                modelContext.insert(connector)
            }
            connectorsByID[connector.id.uuidString] = connector
            if connectorsByName[connector.name] == nil {
                connectorsByName[connector.name] = connector
            }
        }

        var toolsByID: [String: LocalTool] = [:]
        var toolsByName: [String: LocalTool] = [:]
        var skippedLocalToolCount = 0
        for tc in config.localTools ?? [] {
            guard let tool = reusedGlobalTool(for: tc, modelContext: modelContext) ?? makeLocalTool(from: tc) else {
                skippedLocalToolCount += 1
                continue
            }
            tool.workspace = (tool.isGlobal ? nil : workspace)
            if tool.isGlobal {
                appendUnique(tool.id.uuidString, to: &workspace.enabledGlobalToolIDs)
            }
            if tool.modelContext == nil {
                modelContext.insert(tool)
            }
            toolsByID[tool.id.uuidString] = tool
            if toolsByName[tool.name] == nil {
                toolsByName[tool.name] = tool
            }
        }

        var skillsByID: [String: Skill] = [:]
        var skillsByName: [String: Skill] = [:]
        for sc in config.skills {
            let skill = reusedGlobalSkill(for: sc, modelContext: modelContext) ?? makeSkill(from: sc)
            if skill.modelContext == nil {
                modelContext.insert(skill)
            }
            skill.workspace = (skill.isGlobal ? nil : workspace)
            if skill.isGlobal {
                appendUnique(skill.id.uuidString, to: &workspace.enabledGlobalSkillIDs)
            }
            linkResources(
                skill: skill,
                connectorIDs: sc.connectorIDs,
                connectorNames: sc.connectorNames,
                localToolIDs: sc.localToolIDs,
                localToolNames: sc.localToolNames,
                connectorsByID: connectorsByID,
                connectorsByName: connectorsByName,
                toolsByID: toolsByID,
                toolsByName: toolsByName
            )
            skillsByID[skill.id.uuidString] = skill
            if skillsByName[skill.name] == nil {
                skillsByName[skill.name] = skill
            }
        }

        for tc in config.templates ?? [] {
            let template = makeTemplate(from: tc, workspace: workspace)
            modelContext.insert(template)
        }

        if !config.sshConnections.isEmpty && !config.primaryPath.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: config.primaryPath,
                withIntermediateDirectories: true
            )
            SSHConnectionManager.save(config.sshConnections, workspacePath: config.primaryPath)
        }

        let quarantinedScheduleCount = scheduleTrustPolicy.quarantinedScheduleCount(in: config.schedules)
        for sc in config.schedules ?? [] {
            let schedule = makeImportedSchedule(from: sc, workspace: workspace, trustPolicy: scheduleTrustPolicy)
            modelContext.insert(schedule)
        }

        if let taskConfigs = config.tasks {
            for tc in taskConfigs {
                importTask(
                    tc,
                    workspace: workspace,
                    modelContext: modelContext,
                    skillsByID: &skillsByID,
                    skillsByName: &skillsByName,
                    connectorsByID: &connectorsByID,
                    connectorsByName: &connectorsByName,
                    toolsByID: &toolsByID,
                    toolsByName: &toolsByName
                )
            }
        }
        replaceWorkspaceAppMirrorRows(for: workspace.id, modelContext: modelContext)
        // Re-tag every imported row to the workspace actually being created
        // here, not whatever workspaceID its exported config snapshot froze
        // in — those only match when config.id was reused verbatim (a true
        // replace/recovery re-import); a duplicate import intentionally gets
        // a fresh workspace.id (see TaskLifecycleCoordinator.importFromConfig),
        // and without this the freshly-imported rows would silently end up
        // scoped to the ORIGINAL workspace instead of the new one.
        importWorkspaceApps(config.workspaceApps ?? [], workspaceID: workspace.id, modelContext: modelContext)
        importWorkspaceAppRuns(config.workspaceAppRuns ?? [], workspaceID: workspace.id, modelContext: modelContext)
        importWorkspaceAppRunEvents(config.workspaceAppRunEvents ?? [], workspaceID: workspace.id, modelContext: modelContext)
        importWorkspaceAppDependencyBindings(config.workspaceAppDependencyBindings ?? [], workspaceID: workspace.id, modelContext: modelContext)
        importWorkspaceAppAutomationStates(config.workspaceAppAutomationStates ?? [], workspaceID: workspace.id, modelContext: modelContext)
        importGoogleOAuthProfiles(config.googleOAuthAccountProfiles ?? [], modelContext: modelContext)

        let result = WorkspaceConfigImportResult(
            status: .imported,
            workspace: workspace,
            workspaceID: workspace.id.uuidString,
            skillCount: workspace.skills.count,
            connectorCount: workspace.connectors.count,
            localToolCount: workspace.localTools.count,
            taskCount: workspace.tasks.count,
            quarantinedScheduleCount: quarantinedScheduleCount,
            skippedConnectorCount: skippedConnectorCount,
            skippedLocalToolCount: skippedLocalToolCount
        )
        AuditLoggingSeam.required.audit(.workspaceImported, category: "Persistence", fields: result.auditFields, level: .info)
        return result
    }

    // MARK: - Export Helpers

    private static func loadResult(
        status: WorkspaceConfigLoadResult.Status,
        url: URL,
        config: WorkspaceConfig?,
        error: Error?
    ) -> WorkspaceConfigLoadResult {
        let nsError = error.map { $0 as NSError }
        return WorkspaceConfigLoadResult(
            status: status,
            path: url.path,
            config: config,
            errorType: error.map { String(describing: type(of: $0)) },
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: nsError?.localizedDescription
        )
    }

    private static func write(_ config: WorkspaceConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: url)
    }

    private static func fetchGlobalSkills(modelContext: ModelContext) -> [Skill] {
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func fetchGlobalConnectors(modelContext: ModelContext) -> [Connector] {
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func fetchGlobalTools(modelContext: ModelContext) -> [LocalTool] {
        let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func workspaceAppsForExport(workspace: Workspace) -> [WorkspaceApp] {
        guard let modelContext = workspace.modelContext else { return [] }
        let workspaceID = workspace.id
        let descriptor = FetchDescriptor<WorkspaceApp>(predicate: #Predicate { $0.workspaceID == workspaceID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func workspaceAppRunMirrorSnapshotForExport(workspace: Workspace) -> WorkspaceAppRunMirrorSnapshot {
        guard let modelContext = workspace.modelContext else {
            return WorkspaceAppRunMirrorSnapshot(runs: [], events: [])
        }
        let workspaceID = workspace.id
        let runDescriptor = FetchDescriptor<WorkspaceAppRun>(predicate: #Predicate { $0.workspaceID == workspaceID })
        let runs = (try? modelContext.fetch(runDescriptor)) ?? []
        let mirroredRuns = Array(runs
            .sorted(by: workspaceAppRunMirrorOrder)
            .suffix(MirrorLimits.maxWorkspaceAppRuns))
        let mirroredRunIDs = Set(mirroredRuns.map(\.id))

        let eventDescriptor = FetchDescriptor<WorkspaceAppRunEvent>(predicate: #Predicate { $0.workspaceID == workspaceID })
        let events = ((try? modelContext.fetch(eventDescriptor)) ?? [])
            .filter { mirroredRunIDs.contains($0.runID) }
        let mirroredEvents = workspaceAppRunEventsForMirror(events, mirroredRuns: mirroredRuns)

        return WorkspaceAppRunMirrorSnapshot(runs: mirroredRuns, events: mirroredEvents)
    }

    private static func workspaceAppRunMirrorOrder(_ lhs: WorkspaceAppRun, _ rhs: WorkspaceAppRun) -> Bool {
        if lhs.startedAt == rhs.startedAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.startedAt < rhs.startedAt
    }

    private static func workspaceAppRunEventsForMirror(
        _ events: [WorkspaceAppRunEvent],
        mirroredRuns: [WorkspaceAppRun]
    ) -> [WorkspaceAppRunEvent] {
        let approvalWaitingRunIDs = Set(mirroredRuns.compactMap { run -> UUID? in
            guard run.pendingApprovalActionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false else {
                return nil
            }
            return run.id
        })
        let approvalResumeEvents = latestApprovalResumeEvents(
            in: events,
            approvalWaitingRunIDs: approvalWaitingRunIDs
        )
        let approvalResumeEventIDs = Set(approvalResumeEvents.map(\.id))
        let remainingLimit = max(0, MirrorLimits.maxWorkspaceAppRunEvents - approvalResumeEvents.count)
        let recentEvents = Array(events
            .filter { !approvalResumeEventIDs.contains($0.id) }
            .sorted(by: workspaceAppRunEventMirrorOrder)
            .suffix(remainingLimit))
        return (approvalResumeEvents + recentEvents)
            .sorted(by: workspaceAppRunEventMirrorOrder)
    }

    private static func latestApprovalResumeEvents(
        in events: [WorkspaceAppRunEvent],
        approvalWaitingRunIDs: Set<UUID>
    ) -> [WorkspaceAppRunEvent] {
        guard !approvalWaitingRunIDs.isEmpty else { return [] }
        var latestByRunID: [UUID: WorkspaceAppRunEvent] = [:]
        for event in events
            where approvalWaitingRunIDs.contains(event.runID)
                && event.type == "workspaceApp.run.awaitingApproval" {
            guard let existing = latestByRunID[event.runID] else {
                latestByRunID[event.runID] = event
                continue
            }
            if workspaceAppRunEventMirrorOrder(existing, event) {
                latestByRunID[event.runID] = event
            }
        }
        return latestByRunID.values.sorted(by: workspaceAppRunEventMirrorOrder)
    }

    private static func workspaceAppRunEventMirrorOrder(
        _ lhs: WorkspaceAppRunEvent,
        _ rhs: WorkspaceAppRunEvent
    ) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.timestamp < rhs.timestamp
    }

    private static func workspaceAppDependencyBindingsForExport(workspace: Workspace) -> [WorkspaceAppDependencyBinding] {
        guard let modelContext = workspace.modelContext else { return [] }
        let workspaceID = workspace.id
        let descriptor = FetchDescriptor<WorkspaceAppDependencyBinding>(predicate: #Predicate { $0.workspaceID == workspaceID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func workspaceAppAutomationStatesForExport(workspace: Workspace) -> [WorkspaceAppAutomationState] {
        guard let modelContext = workspace.modelContext else { return [] }
        let workspaceID = workspace.id
        let descriptor = FetchDescriptor<WorkspaceAppAutomationState>(predicate: #Predicate { $0.workspaceID == workspaceID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func googleOAuthProfilesForExport(workspace: Workspace) -> [GoogleOAuthAccountProfile] {
        // Google account profiles are GLOBAL account state (subject / email /
        // granted scopes), not workspace-scoped — the model has no workspace
        // link. The workspace mirror is written as a dotfile inside the user's
        // repository, so fetching every profile here mirrored a user's personal
        // Google account metadata into *every* workspace's
        // `.astra-workspace.json`, including unrelated non-Google projects, and
        // into anything the workspace file is later shared with. Account
        // profiles are re-established from Google auth (their tokens live in the
        // keychain, which survives a store reset), so they are deliberately
        // excluded from the per-workspace mirror. Existing mirrors that already
        // contain profiles still import (see importGoogleOAuthProfiles).
        []
    }

    private static func skillsForExport(workspace: Workspace, globalSkills: [Skill]) -> [Skill] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalSkillIDs.compactMap(UUID.init(uuidString:)))
        let taskSkills = workspace.tasks.flatMap(\.skills)
        let enabledGlobals = globalSkills.filter { enabledGlobalIDs.contains($0.id) }
        let all = uniqueByID(workspace.skills + taskSkills + enabledGlobals) { $0.id }
        return all.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private static func connectorsForExport(
        workspace: Workspace,
        skills: [Skill],
        globalConnectors: [Connector]
    ) -> [Connector] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalConnectorIDs.compactMap(UUID.init(uuidString:)))
        let enabledGlobals = globalConnectors.filter { enabledGlobalIDs.contains($0.id) }
        let all = uniqueByID(workspace.connectors + skills.flatMap(\.connectors) + enabledGlobals) { $0.id }
        return all.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private static func toolsForExport(
        workspace: Workspace,
        skills: [Skill],
        globalTools: [LocalTool]
    ) -> [LocalTool] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalToolIDs.compactMap(UUID.init(uuidString:)))
        let enabledGlobals = globalTools.filter { enabledGlobalIDs.contains($0.id) }
        let all = uniqueByID(workspace.localTools + skills.flatMap(\.localTools) + enabledGlobals) { $0.id }
        return all.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private static func skillConfig(_ skill: Skill) -> SkillConfig? {
        // Guard against faulted/deleted SwiftData objects
        guard !skill.isDeleted, skill.modelContext != nil else { return nil }
        return SkillConfig(
            id: skill.id.uuidString,
            name: skill.name,
            icon: skill.icon,
            description: skill.skillDescription,
            allowedTools: skill.allowedTools,
            disallowedTools: skill.disallowedTools,
            customTools: skill.customTools,
            behaviorInstructions: skill.behaviorInstructions,
            environmentKeys: skill.environmentKeys,
            environmentValues: skill.exportableEnvironmentValues,
            isGlobal: skill.isGlobal,
            connectorIDs: skill.connectors.map { $0.id.uuidString },
            localToolIDs: skill.localTools.map { $0.id.uuidString },
            connectorNames: skill.connectors.map(\.name),
            localToolNames: skill.localTools.map(\.name),
            originPackageID: skill.originPackageID,
            originPackageVersion: skill.originPackageVersion,
            originComponentID: skill.originComponentID,
            originComponentKind: skill.originComponentKind,
            originSourceKind: skill.originSourceKind,
            createdAt: skill.createdAt,
            updatedAt: skill.updatedAt
        )
    }

    private static func connectorConfig(_ connector: Connector) -> ConnectorConfig? {
        guard !connector.isDeleted, connector.modelContext != nil else { return nil }
        guard ConnectorSecurityPolicy.isRuntimeSafe(connector) else { return nil }
        return ConnectorConfig(
            id: connector.id.uuidString,
            name: connector.name,
            serviceType: connector.serviceType,
            icon: connector.icon,
            description: connector.connectorDescription,
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: connector.credentialKeys,
            configKeys: connector.configKeys,
            configValues: connector.configValues,
            isGlobal: connector.isGlobal,
            notes: connector.notes,
            originPackageID: connector.originPackageID,
            originPackageVersion: connector.originPackageVersion,
            originComponentID: connector.originComponentID,
            originComponentKind: connector.originComponentKind,
            originSourceKind: connector.originSourceKind,
            createdAt: connector.createdAt,
            updatedAt: connector.updatedAt
        )
    }

    private static func localToolConfig(_ tool: LocalTool) -> LocalToolConfig? {
        guard !tool.isDeleted, tool.modelContext != nil else { return nil }
        guard LocalToolSecurityPolicy.isSafe(command: tool.command, arguments: tool.arguments) else { return nil }
        return LocalToolConfig(
            id: tool.id.uuidString,
            name: tool.name,
            description: tool.toolDescription,
            icon: tool.icon,
            toolType: tool.toolType,
            command: tool.command,
            arguments: tool.arguments,
            isGlobal: tool.isGlobal,
            originPackageID: tool.originPackageID,
            originPackageVersion: tool.originPackageVersion,
            originComponentID: tool.originComponentID,
            originComponentKind: tool.originComponentKind,
            originSourceKind: tool.originSourceKind,
            createdAt: tool.createdAt,
            updatedAt: tool.updatedAt
        )
    }

    private static func templateConfig(_ template: TaskTemplate) -> TemplateConfig {
        TemplateConfig(
            id: template.id.uuidString,
            name: template.name,
            icon: template.icon,
            description: template.templateDescription,
            beforeGoal: template.beforeGoal,
            mainGoal: template.mainGoal,
            afterGoal: template.afterGoal,
            beforeBudget: template.beforeBudget,
            mainBudget: template.mainBudget,
            afterBudget: template.afterBudget,
            beforeModel: template.beforeModel,
            mainModel: template.mainModel,
            afterModel: template.afterModel,
            variablesJSON: template.variablesJSON,
            hooksJSON: template.hooksJSON,
            passContextToMain: template.passContextToMain,
            passContextToAfter: template.passContextToAfter,
            defaultSkillIDs: template.defaultSkillIDs.isEmpty ? nil : template.defaultSkillIDs,
            originPackageID: template.originPackageID,
            originPackageVersion: template.originPackageVersion,
            originComponentID: template.originComponentID,
            originComponentKind: template.originComponentKind,
            originSourceKind: template.originSourceKind,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt
        )
    }

    private static func scheduleConfig(_ schedule: TaskSchedule) -> ScheduleConfig {
        ScheduleConfig(
            id: schedule.id.uuidString,
            name: schedule.name,
            isEnabled: schedule.isEnabled,
            goal: schedule.goal,
            routineDescription: schedule.routineDescription.isEmpty ? nil : schedule.routineDescription,
            routineInstructions: schedule.routineInstructions.isEmpty ? nil : schedule.routineInstructions,
            routinePaths: schedule.routinePaths.isEmpty ? nil : schedule.routinePaths,
            templateID: schedule.templateID?.uuidString,
            templateVariablesJSON: schedule.templateVariablesJSON,
            model: schedule.model,
            tokenBudget: schedule.tokenBudget,
            scheduleType: schedule.scheduleType.rawValue,
            nextFireDate: schedule.nextFireDate,
            intervalSeconds: schedule.intervalSeconds,
            dailyHour: schedule.dailyHour,
            dailyMinute: schedule.dailyMinute,
            weeklyDayOfWeek: schedule.weeklyDayOfWeek,
            fireCount: schedule.fireCount,
            skillIDs: schedule.skillIDs.isEmpty ? nil : schedule.skillIDs,
            conversationContext: schedule.conversationContext.isEmpty ? nil : schedule.conversationContext,
            resultMode: schedule.resultMode.rawValue,
            sourceTaskID: schedule.sourceTaskID?.uuidString,
            runResultsJSON: schedule.runResultsJSON == "[]" ? nil : schedule.runResultsJSON,
            runtimeID: schedule.runtimeID,
            lastFiredAt: schedule.lastFiredAt,
            createdAt: schedule.createdAt,
            updatedAt: schedule.updatedAt
        )
    }

    private static func workspaceAppConfig(_ app: WorkspaceApp) -> WorkspaceAppConfig {
        WorkspaceAppConfig(
            id: app.id.uuidString,
            workspaceID: app.workspaceID.uuidString,
            logicalID: app.logicalID,
            name: app.name,
            icon: app.icon,
            description: app.appDescription,
            lifecycleStatus: app.lifecycleStatusRaw,
            permissionMode: app.permissionModeRaw,
            dependencyStatus: app.dependencyStatusRaw,
            manifestRelativePath: app.manifestRelativePath,
            appDirectoryRelativePath: app.appDirectoryRelativePath,
            manifestDigest: app.manifestDigest,
            publishedManifestDigest: app.publishedManifestDigest,
            lastKnownGoodManifestDigest: app.lastKnownGoodManifestDigest,
            latestVersionNumber: app.latestVersionNumber,
            sourcePackageID: app.sourcePackageID,
            sourcePackageVersion: app.sourcePackageVersion,
            sourcePackageDigest: app.sourcePackageDigest,
            lastOpenedAt: app.lastOpenedAt,
            lastRefreshedAt: app.lastRefreshedAt,
            lastRunAt: app.lastRunAt,
            createdAt: app.createdAt,
            updatedAt: app.updatedAt
        )
    }

    private static func workspaceAppRunConfig(_ run: WorkspaceAppRun) -> WorkspaceAppRunConfig {
        WorkspaceAppRunConfig(
            id: run.id.uuidString,
            workspaceID: run.workspaceID.uuidString,
            appID: run.appID.uuidString,
            appLogicalID: run.appLogicalID,
            actionID: run.actionID,
            trigger: run.triggerRaw,
            status: run.statusRaw,
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            inputSummary: run.inputSummary,
            outputSummary: boundedMirrorString(
                run.outputSummary,
                limit: MirrorLimits.maxWorkspaceAppRunOutputCharacters
            ),
            errorMessage: run.errorMessage,
            linkedTaskID: run.linkedTaskID?.uuidString,
            linkedArtifactPath: run.linkedArtifactPath,
            pendingActionID: run.pendingActionID,
            pendingStepIndex: run.pendingStepIndex,
            consumedTokens: run.consumedTokens,
            awaitedTaskIDsJSON: run.awaitedTaskIDsJSON,
            pendingApprovalActionID: run.pendingApprovalActionID
        )
    }

    private static func workspaceAppRunEventConfig(_ event: WorkspaceAppRunEvent) -> WorkspaceAppRunEventConfig {
        WorkspaceAppRunEventConfig(
            id: event.id.uuidString,
            runID: event.runID.uuidString,
            workspaceID: event.workspaceID.uuidString,
            appID: event.appID.uuidString,
            actionID: event.actionID,
            type: event.type,
            payload: boundedMirrorString(
                event.payload,
                limit: MirrorLimits.maxWorkspaceAppRunEventPayloadCharacters
            ),
            timestamp: event.timestamp
        )
    }

    private static func workspaceAppDependencyBindingConfig(
        _ binding: WorkspaceAppDependencyBinding
    ) -> WorkspaceAppDependencyBindingConfig {
        WorkspaceAppDependencyBindingConfig(
            id: binding.id.uuidString,
            workspaceID: binding.workspaceID.uuidString,
            appID: binding.appID.uuidString,
            appLogicalID: binding.appLogicalID,
            requirementID: binding.requirementID,
            contract: binding.contract,
            operationsSummary: binding.operationsSummary,
            optional: binding.optional,
            status: binding.statusRaw,
            implementationID: binding.implementationID,
            provider: binding.provider,
            transport: binding.transportRaw,
            createdAt: binding.createdAt,
            updatedAt: binding.updatedAt
        )
    }

    private static func workspaceAppAutomationStateConfig(
        _ state: WorkspaceAppAutomationState
    ) -> WorkspaceAppAutomationStateConfig {
        WorkspaceAppAutomationStateConfig(
            id: state.id.uuidString,
            workspaceID: state.workspaceID.uuidString,
            appID: state.appID.uuidString,
            appLogicalID: state.appLogicalID,
            automationID: state.automationID,
            automationType: state.automationType,
            actionID: state.actionID,
            isEnabled: state.isEnabled,
            status: state.statusRaw,
            lastRunAt: state.lastRunAt,
            nextRunAt: state.nextRunAt,
            createdAt: state.createdAt,
            updatedAt: state.updatedAt
        )
    }

    private static func googleOAuthAccountProfileConfig(
        _ profile: GoogleOAuthAccountProfile
    ) -> GoogleOAuthAccountProfileConfig {
        GoogleOAuthAccountProfileConfig(
            id: profile.id.uuidString,
            subject: profile.subject,
            email: profile.email,
            displayName: profile.displayName,
            avatarURLString: profile.avatarURLString,
            hostedDomain: profile.hostedDomain,
            grantedScopes: profile.grantedScopes,
            requestedScopes: profile.requestedScopes,
            authState: profile.authStateRaw,
            authStateReason: profile.authStateReason,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt,
            lastAuthenticatedAt: profile.lastAuthenticatedAt,
            revokedAt: profile.revokedAt
        )
    }

    private static func taskConfig(
        _ task: AgentTask,
        externalOperations: [ExternalOperationConfig] = []
    ) -> TaskConfig {
        let sortedRuns = task.runs.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startedAt < $1.startedAt
        }
        let mirroredRuns = Array(sortedRuns.suffix(MirrorLimits.maxRunsPerTask))
        let runIDToIndex = Dictionary(
            mirroredRuns.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let runConfigs = mirroredRuns.map { run in
            RunConfig(
                id: run.id.uuidString,
                status: run.status.rawValue,
                startedAt: run.startedAt,
                completedAt: run.completedAt,
                tokensUsed: run.tokensUsed,
                inputTokens: run.inputTokens,
                outputTokens: run.outputTokens,
                runtimeID: run.runtimeID,
                providerSessionId: run.providerSessionId,
                providerVersion: run.providerVersion,
                executionEnvironmentSnapshotJSON: run.executionEnvironmentSnapshotJSON,
                providerLaunchSignatureJSON: run.providerLaunchSignatureJSON,
                exitCode: run.exitCode,
                output: boundedMirrorString(run.output, limit: MirrorLimits.maxRunOutputCharacters),
                costUSD: run.costUSD,
                stopReason: run.stopReason,
                fileChangesJSON: run.fileChangesJSON
            )
        }

        let mirroredEvents = Array(task.events
            .sorted {
                if $0.timestamp == $1.timestamp {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.timestamp < $1.timestamp
            }
            .suffix(MirrorLimits.maxEventsPerTask))
        let eventConfigs = mirroredEvents.map { event in
            EventConfig(
                id: event.id.uuidString,
                type: event.type,
                payload: boundedMirrorString(event.payload, limit: MirrorLimits.maxEventPayloadCharacters),
                timestamp: event.timestamp,
                category: event.category,
                agentName: event.agentName,
                agentId: event.agentId,
                teamName: event.teamName,
                runIndex: event.run.flatMap { runIDToIndex[$0.id] }
            )
        }

        let snapshots = (task.skillSnapshots.isEmpty
            ? task.skills.map(SkillSnapshotConfig.init(skill:))
            : task.skillSnapshots).map(redactedSkillSnapshot)

        return TaskConfig(
            id: task.id.uuidString,
            title: task.title,
            goal: task.goal,
            status: task.status.rawValue,
            isPinned: task.isPinned ? true : nil,
            isDone: task.isDone ? true : nil,
            inputs: task.inputs,
            constraints: task.constraints,
            acceptanceCriteria: task.acceptanceCriteria,
            tokenBudget: task.tokenBudget,
            tokensUsed: task.tokensUsed,
            model: task.model,
            runtimeID: task.runtimeID,
            runtimeExplicitlySelected: task.runtimeExplicitlySelected ? true : nil,
            costUSD: task.costUSD,
            sessionId: task.sessionId,
            maxTurns: task.maxTurns,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            completedAt: task.completedAt,
            unreadAt: task.unreadAt,
            isolationStrategy: task.isolationStrategy.rawValue,
            validationStrategy: task.validationStrategy.rawValue,
            testCommand: task.testCommand,
            draftMessages: task.draftMessages,
            chainedGoal: task.chainedGoal,
            chainedFromID: task.chainedFromID?.uuidString,
            useAgentTeam: task.useAgentTeam,
            teamSize: task.teamSize,
            teamInstructions: task.teamInstructions,
            templateID: task.templateID?.uuidString,
            templateHooksJSON: task.templateHooksJSON,
            queuePosition: task.queuePosition,
            forkedFromID: task.forkedFromID?.uuidString,
            forkedAtRunIndex: task.forkedAtRunIndex,
            originScheduleID: task.originScheduleID?.uuidString,
            executionRootPath: task.executionRootPath,
            runs: runConfigs,
            events: eventConfigs,
            artifacts: task.artifacts.map(ArtifactConfig.init(artifact:)),
            skillIDs: task.skills.map { $0.id.uuidString },
            skillNames: task.skills.map(\.name),
            skillSnapshots: snapshots,
            executionEnvironmentSnapshotJSON: sanitizedExecutionEnvironmentJSON(task.executionEnvironmentSnapshotJSON, preservingHost: true),
            runtimePermissionOpenRequestsJSON: task.runtimePermissionOpenRequestsJSON == "[]" ? nil : task.runtimePermissionOpenRequestsJSON,
            runtimePermissionGrantsJSON: task.runtimePermissionGrantsJSON == "[]" ? nil : task.runtimePermissionGrantsJSON,
            rememberedWorkspaceCanvasItemRawValue: task.rememberedWorkspaceCanvasItemRawValue,
            externalOperations: externalOperations.isEmpty ? nil : externalOperations
        )
    }

    private static func boundedMirrorString(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let marker = "\n[ASTRA mirror truncated: original \(value.count) characters; limit \(limit) characters]"
        let retainedCount = max(0, limit - marker.count)
        return String(value.prefix(retainedCount)) + marker
    }

    private static func uniqueByID<T>(_ values: [T], id: (T) -> UUID) -> [T] {
        var seen = Set<UUID>()
        var result: [T] = []
        for value in values {
            let valueID = id(value)
            guard !seen.contains(valueID) else { continue }
            seen.insert(valueID)
            result.append(value)
        }
        return result
    }

    private static func sanitizedExecutionEnvironmentJSON(_ json: String?, preservingHost: Bool = false) -> String? {
        let environment = ExecutionEnvironmentStore.decode(json)
        return preservingHost
            ? ExecutionEnvironmentStore.encodeSnapshot(environment)
            : ExecutionEnvironmentStore.encode(environment)
    }

    // MARK: - Import Helpers

    private static func makeConnector(from config: ConnectorConfig) -> Connector? {
        guard ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: config.baseURL,
            authMethod: config.authMethod,
            credentialKeys: config.credentialKeys
        ) == nil else {
            return nil
        }
        let connector = Connector(
            name: config.name,
            serviceType: config.serviceType,
            icon: config.icon,
            connectorDescription: config.description,
            baseURL: config.baseURL,
            authMethod: config.authMethod
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            connector.id = id
        }
        connector.credentialKeys = config.credentialKeys
        connector.credentialValues = Array(repeating: "", count: config.credentialKeys.count)
        connector.configKeys = config.configKeys
        connector.configValues = config.configValues
        connector.isGlobal = config.isGlobal ?? false
        connector.notes = config.notes
        connector.originPackageID = config.originPackageID
        connector.originPackageVersion = config.originPackageVersion
        connector.originComponentID = config.originComponentID
        connector.originComponentKind = config.originComponentKind
        connector.originSourceKind = config.originSourceKind
        connector.createdAt = config.createdAt ?? connector.createdAt
        connector.updatedAt = config.updatedAt ?? connector.updatedAt
        return connector
    }

    private static func makeConnector(from snapshot: ConnectorSnapshotConfig, workspace: Workspace) -> Connector? {
        guard ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: snapshot.baseURL,
            authMethod: snapshot.authMethod,
            credentialKeys: snapshot.credentialKeys
        ) == nil else {
            return nil
        }
        let connector = Connector(
            name: snapshot.name,
            serviceType: snapshot.serviceType,
            icon: snapshot.icon,
            connectorDescription: snapshot.description,
            baseURL: snapshot.baseURL,
            authMethod: snapshot.authMethod
        )
        if let id = snapshot.id.flatMap(UUID.init(uuidString:)) {
            connector.id = id
        }
        connector.credentialKeys = snapshot.credentialKeys
        connector.credentialValues = Array(repeating: "", count: snapshot.credentialKeys.count)
        connector.configKeys = snapshot.configKeys
        connector.configValues = snapshot.configValues
        connector.isGlobal = false
        connector.notes = snapshot.notes
        connector.createdAt = snapshot.createdAt ?? connector.createdAt
        connector.updatedAt = snapshot.updatedAt ?? connector.updatedAt
        connector.workspace = workspace
        return connector
    }

    private static func makeLocalTool(from config: LocalToolConfig) -> LocalTool? {
        guard LocalToolSecurityPolicy.isSafe(command: config.command, arguments: config.arguments) else {
            return nil
        }
        let tool = LocalTool(
            name: config.name,
            toolDescription: config.description,
            icon: config.icon,
            toolType: config.toolType,
            command: config.command,
            arguments: config.arguments
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            tool.id = id
        }
        tool.isGlobal = config.isGlobal ?? false
        tool.originPackageID = config.originPackageID
        tool.originPackageVersion = config.originPackageVersion
        tool.originComponentID = config.originComponentID
        tool.originComponentKind = config.originComponentKind
        tool.originSourceKind = config.originSourceKind
        tool.createdAt = config.createdAt ?? tool.createdAt
        tool.updatedAt = config.updatedAt ?? tool.updatedAt
        return tool
    }

    private static func makeLocalTool(from snapshot: LocalToolSnapshotConfig, workspace: Workspace) -> LocalTool? {
        guard LocalToolSecurityPolicy.isSafe(command: snapshot.command, arguments: snapshot.arguments) else {
            return nil
        }
        let tool = LocalTool(
            name: snapshot.name,
            toolDescription: snapshot.description,
            icon: snapshot.icon,
            toolType: snapshot.toolType,
            command: snapshot.command,
            arguments: snapshot.arguments
        )
        if let id = snapshot.id.flatMap(UUID.init(uuidString:)) {
            tool.id = id
        }
        tool.isGlobal = false
        tool.createdAt = snapshot.createdAt ?? tool.createdAt
        tool.updatedAt = snapshot.updatedAt ?? tool.updatedAt
        tool.workspace = workspace
        return tool
    }

    private static func makeSkill(from config: SkillConfig) -> Skill {
        let skill = Skill(
            name: config.name,
            icon: config.icon,
            skillDescription: config.description,
            allowedTools: config.allowedTools,
            disallowedTools: config.disallowedTools,
            customTools: config.customTools,
            behaviorInstructions: config.behaviorInstructions
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            skill.id = id
        }
        skill.environmentKeys = config.environmentKeys
        let storedValues = Array(config.environmentValues.prefix(config.environmentKeys.count))
        skill.environmentValues = storedValues + Array(repeating: "", count: max(0, config.environmentKeys.count - storedValues.count))
        let builtIn = Skill.isBuiltInName(config.name)
        skill.isBuiltIn = builtIn
        skill.isGlobal = builtIn || (config.isGlobal ?? false)
        skill.originPackageID = config.originPackageID
        skill.originPackageVersion = config.originPackageVersion
        skill.originComponentID = config.originComponentID
        skill.originComponentKind = config.originComponentKind
        skill.originSourceKind = config.originSourceKind
        skill.createdAt = config.createdAt ?? skill.createdAt
        skill.updatedAt = config.updatedAt ?? skill.updatedAt
        skill.migrateSecretsToKeychain()
        return skill
    }

    private static func makeRestoredSkill(from snapshot: SkillSnapshotConfig, workspace: Workspace) -> Skill {
        let restoredName = snapshot.name.hasSuffix(" (Restored)") ? snapshot.name : "\(snapshot.name) (Restored)"
        let restoredDescription = snapshot.description.isEmpty
            ? "Restored from task history snapshot."
            : "\(snapshot.description)\n\nRestored from task history snapshot."
        let skill = Skill(
            name: restoredName,
            icon: snapshot.icon,
            skillDescription: restoredDescription,
            allowedTools: snapshot.allowedTools,
            disallowedTools: snapshot.disallowedTools,
            customTools: snapshot.customTools,
            behaviorInstructions: snapshot.behaviorInstructions
        )
        if let id = snapshot.id.flatMap(UUID.init(uuidString:)) {
            skill.id = id
        }
        skill.environmentKeys = snapshot.environmentKeys
        let storedValues = Array(snapshot.environmentValues.prefix(snapshot.environmentKeys.count))
        skill.environmentValues = storedValues + Array(repeating: "", count: max(0, snapshot.environmentKeys.count - storedValues.count))
        skill.isGlobal = false
        skill.createdAt = snapshot.createdAt ?? skill.createdAt
        skill.updatedAt = Date()
        skill.workspace = workspace
        skill.migrateSecretsToKeychain()
        return skill
    }

    private static func makeTemplate(from config: TemplateConfig, workspace: Workspace) -> TaskTemplate {
        let template = TaskTemplate(
            name: config.name,
            mainGoal: config.mainGoal,
            workspace: workspace,
            icon: config.icon,
            templateDescription: config.description
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            template.id = id
        }
        template.beforeGoal = config.beforeGoal
        template.afterGoal = config.afterGoal
        template.beforeBudget = config.beforeBudget
        template.mainBudget = config.mainBudget
        template.afterBudget = config.afterBudget
        template.beforeModel = config.beforeModel
        template.mainModel = config.mainModel
        template.afterModel = config.afterModel
        template.variablesJSON = config.variablesJSON
        template.hooksJSON = config.hooksJSON
        template.passContextToMain = config.passContextToMain
        template.passContextToAfter = config.passContextToAfter
        template.defaultSkillIDs = config.defaultSkillIDs ?? []
        template.originPackageID = config.originPackageID
        template.originPackageVersion = config.originPackageVersion
        template.originComponentID = config.originComponentID
        template.originComponentKind = config.originComponentKind
        template.originSourceKind = config.originSourceKind
        template.createdAt = config.createdAt ?? template.createdAt
        template.updatedAt = config.updatedAt ?? template.updatedAt
        return template
    }

    private static func redactedSkillSnapshot(_ snapshot: SkillSnapshotConfig) -> SkillSnapshotConfig {
        SkillSnapshotConfig(
            id: snapshot.id,
            name: snapshot.name,
            icon: snapshot.icon,
            description: snapshot.description,
            allowedTools: snapshot.allowedTools,
            disallowedTools: snapshot.disallowedTools,
            customTools: snapshot.customTools,
            behaviorInstructions: snapshot.behaviorInstructions,
            environmentKeys: snapshot.environmentKeys,
            environmentValues: Array(repeating: "", count: snapshot.environmentKeys.count),
            isGlobal: snapshot.isGlobal,
            connectorIDs: snapshot.connectorIDs,
            localToolIDs: snapshot.localToolIDs,
            connectorSnapshots: snapshot.connectorSnapshots,
            localToolSnapshots: snapshot.localToolSnapshots,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
    }

    private static func makeImportedSchedule(
        from config: ScheduleConfig,
        workspace: Workspace,
        trustPolicy: ScheduleImportTrustPolicy
    ) -> TaskSchedule {
        let schedule = TaskSchedule(
            name: config.name,
            goal: config.goal,
            workspace: workspace,
            runtimeID: config.runtimeID ?? AgentRuntimeID.claudeCode.rawValue,
            model: config.model,
            tokenBudget: config.tokenBudget,
            scheduleType: ScheduleType(rawValue: config.scheduleType) ?? .once,
            nextFireDate: config.nextFireDate
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            schedule.id = id
        }
        schedule.isEnabled = trustPolicy.enabledState(for: config)
        schedule.templateID = config.templateID.flatMap(UUID.init(uuidString:))
        schedule.templateVariablesJSON = config.templateVariablesJSON
        schedule.routineDescription = config.routineDescription ?? schedule.routineDescription
        schedule.routineInstructions = config.routineInstructions ?? schedule.routineInstructions
        schedule.routinePaths = config.routinePaths ?? schedule.routinePaths
        schedule.intervalSeconds = config.intervalSeconds
        schedule.dailyHour = config.dailyHour
        schedule.dailyMinute = config.dailyMinute
        schedule.weeklyDayOfWeek = config.weeklyDayOfWeek
        schedule.fireCount = config.fireCount
        schedule.skillIDs = config.skillIDs ?? []
        schedule.conversationContext = config.conversationContext ?? ""
        schedule.resultMode = config.resultMode.flatMap(ScheduleResultMode.init(rawValue:)) ?? .sameThread
        schedule.sourceTaskID = config.sourceTaskID.flatMap(UUID.init(uuidString:))
        schedule.runResultsJSON = config.runResultsJSON ?? "[]"
        schedule.lastFiredAt = config.lastFiredAt
        schedule.createdAt = config.createdAt ?? schedule.createdAt
        schedule.updatedAt = config.updatedAt ?? schedule.updatedAt
        return schedule
    }

    private static func reusedGlobalSkill(for config: SkillConfig, modelContext: ModelContext) -> Skill? {
        guard config.isGlobal == true || Skill.isBuiltInName(config.name) else {
            return nil
        }

        if let idString = config.id,
           let id = UUID(uuidString: idString) {
            let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id && $0.isGlobal })
            if let exact = (try? modelContext.fetch(descriptor))?.first {
                return exact
            }
        }

        guard Skill.isBuiltInName(config.name) else { return nil }
        let name = config.name
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.name == name && $0.isGlobal })
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func reusedGlobalConnector(for config: ConnectorConfig, modelContext: ModelContext) -> Connector? {
        guard config.isGlobal == true else { return nil }
        guard ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: config.baseURL,
            authMethod: config.authMethod,
            credentialKeys: config.credentialKeys
        ) == nil else {
            return nil
        }

        if let idString = config.id,
           let id = UUID(uuidString: idString) {
            let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id && $0.isGlobal })
            if let exact = (try? modelContext.fetch(descriptor))?.first {
                return exact
            }
        }

        let name = config.name
        let serviceType = config.serviceType
        let baseURL = config.baseURL
        let descriptor = FetchDescriptor<Connector>(
            predicate: #Predicate {
                $0.name == name &&
                $0.serviceType == serviceType &&
                $0.baseURL == baseURL &&
                $0.isGlobal
            }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func reusedGlobalTool(for config: LocalToolConfig, modelContext: ModelContext) -> LocalTool? {
        guard config.isGlobal == true else { return nil }
        guard LocalToolSecurityPolicy.isSafe(command: config.command, arguments: config.arguments) else {
            return nil
        }

        if let idString = config.id,
           let id = UUID(uuidString: idString) {
            let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == id && $0.isGlobal })
            if let exact = (try? modelContext.fetch(descriptor))?.first {
                return exact
            }
        }

        let name = config.name
        let toolType = config.toolType
        let command = config.command
        let arguments = config.arguments
        let descriptor = FetchDescriptor<LocalTool>(
            predicate: #Predicate {
                $0.name == name &&
                $0.toolType == toolType &&
                $0.command == command &&
                $0.arguments == arguments &&
                $0.isGlobal
            }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func linkResources(
        skill: Skill,
        connectorIDs: [String]?,
        connectorNames: [String]?,
        localToolIDs: [String]?,
        localToolNames: [String]?,
        connectorsByID: [String: Connector],
        connectorsByName: [String: Connector],
        toolsByID: [String: LocalTool],
        toolsByName: [String: LocalTool]
    ) {
        if let connectorIDs, !connectorIDs.isEmpty {
            for id in connectorIDs {
                connectorsByID[id]?.skill = skill
            }
        } else {
            for name in connectorNames ?? [] {
                connectorsByName[name]?.skill = skill
            }
        }

        if let localToolIDs, !localToolIDs.isEmpty {
            for id in localToolIDs {
                toolsByID[id]?.skill = skill
            }
        } else {
            for name in localToolNames ?? [] {
                toolsByName[name]?.skill = skill
            }
        }
    }

    @MainActor
    private static func importTask(
        _ config: TaskConfig,
        workspace: Workspace,
        modelContext: ModelContext,
        skillsByID: inout [String: Skill],
        skillsByName: inout [String: Skill],
        connectorsByID: inout [String: Connector],
        connectorsByName: inout [String: Connector],
        toolsByID: inout [String: LocalTool],
        toolsByName: inout [String: LocalTool]
    ) {
        let importedRuntime = config.runtimeID.flatMap(AgentRuntimeID.init(rawValue:)) ?? .claudeCode
        let task = AgentTask(
            title: config.title,
            goal: config.goal,
            workspace: workspace,
            tokenBudget: config.tokenBudget,
            model: config.model,
            runtime: importedRuntime
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            task.id = id
        }
        let targetStatus = TaskStatus(rawValue: config.status) ?? .completed
        let restorationResult = TaskSessionStateApplyingSeam.required.restoreImportedStatus(
            taskID: task.id,
            currentStatusRawValue: task.status.rawValue,
            targetStatusRawValue: targetStatus.rawValue,
            at: Date()
        )
        task.status = targetStatus
        task.updatedAt = restorationResult.updatedAt
        task.isPinned = config.isPinned ?? false
        task.isDone = config.isDone ?? false
        task.inputs = config.inputs
        task.constraints = config.constraints
        task.acceptanceCriteria = config.acceptanceCriteria
        task.tokensUsed = config.tokensUsed
        task.runtimeID = importedRuntime.rawValue
        task.runtimeExplicitlySelected = config.runtimeExplicitlySelected ?? false
        task.costUSD = config.costUSD
        task.sessionId = config.sessionId
        task.maxTurns = config.maxTurns
        task.createdAt = config.createdAt
        task.updatedAt = config.updatedAt
        task.completedAt = config.completedAt
        task.unreadAt = config.unreadAt
        if let value = config.isolationStrategy {
            task.isolationStrategy = IsolationStrategy(rawValue: value) ?? .sameDirectory
        }
        let validation = importedValidationConfiguration(
            strategy: config.validationStrategy,
            testCommand: config.testCommand,
            workspacePath: workspace.primaryPath
        )
        task.validationStrategy = validation.strategy
        task.testCommand = validation.testCommand
        task.draftMessages = config.draftMessages ?? ""
        task.chainedGoal = config.chainedGoal ?? ""
        if let id = config.chainedFromID {
            task.chainedFromID = UUID(uuidString: id)
        }
        task.queuePosition = config.queuePosition ?? 0
        task.forkedFromID = config.forkedFromID.flatMap(UUID.init(uuidString:))
        task.forkedAtRunIndex = config.forkedAtRunIndex ?? 0
        task.originScheduleID = config.originScheduleID.flatMap(UUID.init(uuidString:))
        task.executionRootPath = config.executionRootPath
        task.useAgentTeam = config.useAgentTeam ?? false
        task.teamSize = config.teamSize ?? 3
        task.teamInstructions = config.teamInstructions ?? ""
        if let id = config.templateID {
            task.templateID = UUID(uuidString: id)
        }
        task.templateHooksJSON = config.templateHooksJSON ?? ""
        task.skillSnapshots = config.skillSnapshots ?? []
        task.executionEnvironmentSnapshotJSON = sanitizedExecutionEnvironmentJSON(
            config.executionEnvironmentSnapshotJSON,
            preservingHost: true
        )
        // A missing `runtimePermissionOpenRequestsJSON` in the config is
        // ambiguous: export normalizes an explicit "[]" tombstone to nil
        // (line above, mirrored below), so a genuinely legacy/pre-typed-store
        // task (which never had typed state at all) is indistinguishable
        // from one that was deliberately closed. Backfilling "[]" here used
        // to collapse both into a typed tombstone, which made
        // `TaskRuntimePermissionOpenRequestStore` skip its legacy
        // `permission.approval.requested` compatibility fallback and lose a
        // pendingUser task's resumable approval payload/grants. Leave it nil
        // instead — `TaskRuntimePermissionOpenRequestStore` already treats
        // nil as "missing typed state" and falls back to compatibility
        // events, while a task's *own* requestID-correlated
        // `permission.request.resolved` events (imported alongside it) still
        // keep an actually-resolved request closed.
        task.runtimePermissionOpenRequestsJSON = config.runtimePermissionOpenRequestsJSON
        task.runtimePermissionGrantsJSON = config.runtimePermissionGrantsJSON ?? "[]"
        task.rememberedWorkspaceCanvasItemRawValue = config.rememberedWorkspaceCanvasItemRawValue
        modelContext.insert(task)

        linkSkills(
            to: task,
            skillIDs: config.skillIDs,
            legacySkillNames: config.skillNames,
            snapshots: config.skillSnapshots ?? [],
            workspace: workspace,
            modelContext: modelContext,
            skillsByID: &skillsByID,
            skillsByName: &skillsByName,
            connectorsByID: &connectorsByID,
            connectorsByName: &connectorsByName,
            toolsByID: &toolsByID,
            toolsByName: &toolsByName
        )
        if task.skillSnapshots.isEmpty {
            TaskCapabilitySnapshotCapture.capture(for: task)
        }

        var importedRuns: [TaskRun] = []
        for rc in config.runs {
            let run = TaskRun(task: task)
            if let id = rc.id.flatMap(UUID.init(uuidString:)) {
                run.id = id
            }
            run.status = RunStatus(rawValue: rc.status) ?? .completed
            run.startedAt = rc.startedAt
            run.completedAt = rc.completedAt
            run.tokensUsed = rc.tokensUsed
            run.inputTokens = rc.inputTokens ?? 0
            run.outputTokens = rc.outputTokens ?? 0
            run.runtimeID = rc.runtimeID ?? task.runtimeID
            run.providerSessionId = rc.providerSessionId
            run.providerVersion = rc.providerVersion
            run.executionEnvironmentSnapshotJSON = sanitizedExecutionEnvironmentJSON(
                rc.executionEnvironmentSnapshotJSON,
                preservingHost: true
            )
            run.providerLaunchSignatureJSON = rc.providerLaunchSignatureJSON
            run.exitCode = rc.exitCode
            run.output = rc.output
            run.costUSD = rc.costUSD
            run.stopReason = rc.stopReason
            run.fileChangesJSON = rc.fileChangesJSON
            modelContext.insert(run)
            importedRuns.append(run)
        }

        importQuarantinedExternalOperations(
            config.externalOperations ?? [],
            task: task,
            importedRuns: importedRuns,
            modelContext: modelContext
        )

        for ec in config.events {
            let run = ec.runIndex.flatMap { index in
                index < importedRuns.count ? importedRuns[index] : nil
            }
            let event = TaskEvent(
                task: task,
                type: ec.type,
                payload: ec.payload,
                run: run,
                agentName: ec.agentName,
                agentId: ec.agentId,
                teamName: ec.teamName
            )
            if let id = ec.id.flatMap(UUID.init(uuidString:)) {
                event.id = id
            }
            event.timestamp = ec.timestamp
            event.category = ec.category
            modelContext.insert(event)
        }
        task.updatedAt = config.updatedAt

        for ac in config.artifacts ?? [] {
            let artifact = Artifact(
                task: task,
                type: ac.type,
                path: ac.path,
                content: ac.content,
                version: ac.version
            )
            if let id = ac.id.flatMap(UUID.init(uuidString:)) {
                artifact.id = id
            }
            artifact.createdAt = ac.createdAt
            modelContext.insert(artifact)
        }
    }

    /// Generates fresh ids for every WorkspaceApp/Run/RunEvent/DependencyBinding/
    /// AutomationState in `config` and rewrites every `appID`/`runID`
    /// cross-reference to match. A duplicated workspace must not share these
    /// primary keys with the workspace it was exported from — code such as
    /// `WorkspaceAppService.deleteApp` operates by `appID` alone across runs,
    /// bindings, automation, and events, so a shared id lets an operation on
    /// one copy affect the other.
    public static func remappingWorkspaceAppIdentities(in config: WorkspaceConfig) -> WorkspaceConfig {
        var config = config
        var appIDRemap: [String: String] = [:]
        var runIDRemap: [String: String] = [:]

        config.workspaceApps = config.workspaceApps?.map { app in
            var app = app
            if let oldID = app.id {
                let newID = UUID().uuidString
                appIDRemap[oldID] = newID
                app.id = newID
            }
            return app
        }

        config.workspaceAppRuns = config.workspaceAppRuns?.map { run in
            var run = run
            if let oldID = run.id {
                let newID = UUID().uuidString
                runIDRemap[oldID] = newID
                run.id = newID
            }
            run.appID = appIDRemap[run.appID] ?? run.appID
            return run
        }

        config.workspaceAppRunEvents = config.workspaceAppRunEvents?.map { event in
            var event = event
            if event.id != nil {
                event.id = UUID().uuidString
            }
            event.runID = runIDRemap[event.runID] ?? event.runID
            event.appID = appIDRemap[event.appID] ?? event.appID
            return event
        }

        config.workspaceAppDependencyBindings = config.workspaceAppDependencyBindings?.map { binding in
            var binding = binding
            if binding.id != nil {
                binding.id = UUID().uuidString
            }
            binding.appID = appIDRemap[binding.appID] ?? binding.appID
            return binding
        }

        config.workspaceAppAutomationStates = config.workspaceAppAutomationStates?.map { state in
            var state = state
            if state.id != nil {
                state.id = UUID().uuidString
            }
            state.appID = appIDRemap[state.appID] ?? state.appID
            return state
        }

        return config
    }

    /// Generates fresh ids for every AgentTask/TaskRun in `config` and rewrites
    /// the task-id cross-references (`chainedFromID`, `forkedFromID`,
    /// `ScheduleConfig.sourceTaskID`) to match. A duplicated workspace must not
    /// share task/run primary keys with the workspace it was exported from:
    /// `TaskExternalOperation` and its controls/services are keyed globally by
    /// scalar `taskID` (no workspace scoping), so a duplicate task retaining
    /// the original UUID could observe, poll, stop, or cancel the ORIGINAL
    /// task's live external job — and startup trusted-record reconciliation
    /// could adopt the original's backend receipt onto the duplicate. Exported
    /// task events reference runs by index, not id, so only `RunConfig.id`
    /// itself needs regeneration.
    public static func remappingTaskIdentities(in config: WorkspaceConfig) -> WorkspaceConfig {
        var config = config
        var taskIDRemap: [String: String] = [:]

        config.tasks = config.tasks?.map { task in
            var task = task
            if let oldID = task.id {
                let newID = UUID().uuidString
                taskIDRemap[oldID] = newID
                task.id = newID
            }
            task.runs = task.runs.map { run in
                var run = run
                if run.id != nil {
                    run.id = UUID().uuidString
                }
                return run
            }
            return task
        }

        // Second pass: cross-references may point at a task defined later in
        // the array, so they can only be rewritten once the full remap exists.
        // References to tasks outside this config (already absent from the
        // duplicate) are left as-is; they simply dangle like they would after
        // deleting the referenced task.
        config.tasks = config.tasks?.map { task in
            var task = task
            task.chainedFromID = task.chainedFromID.flatMap { taskIDRemap[$0] ?? $0 }
            task.forkedFromID = task.forkedFromID.flatMap { taskIDRemap[$0] ?? $0 }
            return task
        }

        config.schedules = config.schedules?.map { schedule in
            var schedule = schedule
            schedule.sourceTaskID = schedule.sourceTaskID.flatMap { taskIDRemap[$0] ?? $0 }
            return schedule
        }

        // Workspace App runs reference tasks too: `linkedTaskID` and the UUIDs
        // inside `awaitedTaskIDsJSON` are resolved GLOBALLY by
        // WorkspaceAppRunResumptionService, so leaving them pointing at the
        // original workspace's tasks would resume the duplicate's workflow
        // with the original tasks' outputs (or fail it based on their state).
        config.workspaceAppRuns = config.workspaceAppRuns?.map { run in
            var run = run
            run.linkedTaskID = run.linkedTaskID.flatMap { taskIDRemap[$0] ?? $0 }
            if let awaitedJSON = run.awaitedTaskIDsJSON,
               let data = awaitedJSON.data(using: .utf8),
               let awaitedIDs = try? JSONDecoder().decode([String].self, from: data) {
                let remapped = awaitedIDs.map { taskIDRemap[$0] ?? $0 }
                if let encoded = try? JSONEncoder().encode(remapped),
                   let rendered = String(data: encoded, encoding: .utf8) {
                    run.awaitedTaskIDsJSON = rendered
                }
            }
            return run
        }

        return config
    }

    private static func importWorkspaceApps(_ configs: [WorkspaceAppConfig], workspaceID: UUID, modelContext: ModelContext) {
        for config in configs {
            let app = WorkspaceApp(
                id: config.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                workspaceID: workspaceID,
                logicalID: config.logicalID,
                name: config.name,
                icon: config.icon,
                appDescription: config.description,
                lifecycleStatus: WorkspaceAppLifecycleStatus(rawValue: config.lifecycleStatus) ?? .draft,
                permissionMode: WorkspaceAppPermissionMode(rawValue: config.permissionMode) ?? .readOnly,
                dependencyStatus: WorkspaceAppDependencyStatus(rawValue: config.dependencyStatus) ?? .unresolved,
                manifestRelativePath: config.manifestRelativePath,
                appDirectoryRelativePath: config.appDirectoryRelativePath,
                manifestDigest: config.manifestDigest,
                publishedManifestDigest: config.publishedManifestDigest ?? "",
                lastKnownGoodManifestDigest: config.lastKnownGoodManifestDigest ?? "",
                latestVersionNumber: config.latestVersionNumber ?? 0,
                sourcePackageID: config.sourcePackageID,
                sourcePackageVersion: config.sourcePackageVersion,
                sourcePackageDigest: config.sourcePackageDigest,
                createdAt: config.createdAt ?? Date(),
                updatedAt: config.updatedAt ?? config.createdAt ?? Date()
            )
            app.lastOpenedAt = config.lastOpenedAt
            app.lastRefreshedAt = config.lastRefreshedAt
            app.lastRunAt = config.lastRunAt
            modelContext.insert(app)
        }
    }

    private static func importWorkspaceAppRuns(_ configs: [WorkspaceAppRunConfig], workspaceID: UUID, modelContext: ModelContext) {
        for config in configs {
            let run = WorkspaceAppRun(
                id: config.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                workspaceID: workspaceID,
                appID: UUID(uuidString: config.appID) ?? UUID(),
                appLogicalID: config.appLogicalID,
                actionID: config.actionID,
                trigger: WorkspaceAppRunTrigger(rawValue: config.trigger) ?? .user,
                status: WorkspaceAppRunStatus(rawValue: config.status) ?? .failed,
                startedAt: config.startedAt,
                inputSummary: config.inputSummary,
                outputSummary: config.outputSummary,
                errorMessage: config.errorMessage
            )
            run.completedAt = config.completedAt
            run.linkedTaskID = config.linkedTaskID.flatMap(UUID.init(uuidString:))
            run.linkedArtifactPath = config.linkedArtifactPath
            run.pendingActionID = config.pendingActionID
            run.pendingStepIndex = config.pendingStepIndex ?? 0
            run.consumedTokens = config.consumedTokens ?? 0
            run.awaitedTaskIDsJSON = config.awaitedTaskIDsJSON ?? "[]"
            run.pendingApprovalActionID = config.pendingApprovalActionID
            modelContext.insert(run)
        }
    }

    private static func importWorkspaceAppRunEvents(
        _ configs: [WorkspaceAppRunEventConfig],
        workspaceID: UUID,
        modelContext: ModelContext
    ) {
        for config in configs {
            let event = WorkspaceAppRunEvent(
                id: config.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                runID: UUID(uuidString: config.runID) ?? UUID(),
                workspaceID: workspaceID,
                appID: UUID(uuidString: config.appID) ?? UUID(),
                actionID: config.actionID,
                type: config.type,
                payload: config.payload,
                timestamp: config.timestamp
            )
            modelContext.insert(event)
        }
    }

    private static func importWorkspaceAppDependencyBindings(
        _ configs: [WorkspaceAppDependencyBindingConfig],
        workspaceID: UUID,
        modelContext: ModelContext
    ) {
        for config in configs {
            let binding = WorkspaceAppDependencyBinding(
                id: config.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                workspaceID: workspaceID,
                appID: UUID(uuidString: config.appID) ?? UUID(),
                appLogicalID: config.appLogicalID,
                requirementID: config.requirementID,
                contract: config.contract,
                operations: config.operationsSummary
                    .split(separator: ",")
                    .map(String.init)
                    .filter { !$0.isEmpty },
                optional: config.optional,
                status: WorkspaceAppDependencyBindingStatus(rawValue: config.status) ?? .missingRequired,
                implementationID: config.implementationID,
                provider: config.provider,
                transport: config.transport.flatMap(WorkspaceAppContractTransport.init(rawValue:)),
                createdAt: config.createdAt ?? Date(),
                updatedAt: config.updatedAt ?? config.createdAt ?? Date()
            )
            modelContext.insert(binding)
        }
    }

    private static func importWorkspaceAppAutomationStates(
        _ configs: [WorkspaceAppAutomationStateConfig],
        workspaceID: UUID,
        modelContext: ModelContext
    ) {
        for config in configs {
            let state = WorkspaceAppAutomationState(
                id: config.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                workspaceID: workspaceID,
                appID: UUID(uuidString: config.appID) ?? UUID(),
                appLogicalID: config.appLogicalID,
                automationID: config.automationID,
                automationType: config.automationType,
                actionID: config.actionID,
                isEnabled: config.isEnabled,
                status: WorkspaceAppAutomationStateStatus(rawValue: config.status) ?? .disabled,
                lastRunAt: config.lastRunAt,
                nextRunAt: config.nextRunAt,
                createdAt: config.createdAt ?? Date(),
                updatedAt: config.updatedAt ?? config.createdAt ?? Date()
            )
            modelContext.insert(state)
        }
    }

    private static func importGoogleOAuthProfiles(
        _ configs: [GoogleOAuthAccountProfileConfig],
        modelContext: ModelContext
    ) {
        for config in configs {
            guard existingGoogleOAuthProfile(for: config, modelContext: modelContext) == nil else {
                continue
            }
            let profile = GoogleOAuthAccountProfile(
                id: config.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                subject: config.subject,
                email: config.email,
                displayName: config.displayName,
                avatarURLString: config.avatarURLString,
                hostedDomain: config.hostedDomain,
                grantedScopes: config.grantedScopes,
                requestedScopes: config.requestedScopes,
                authState: GoogleOAuthAccountAuthState(rawValue: config.authState) ?? .active,
                authStateReason: config.authStateReason,
                createdAt: config.createdAt,
                updatedAt: config.updatedAt,
                lastAuthenticatedAt: config.lastAuthenticatedAt,
                revokedAt: config.revokedAt
            )
            modelContext.insert(profile)
        }
    }

    private static func existingGoogleOAuthProfile(
        for config: GoogleOAuthAccountProfileConfig,
        modelContext: ModelContext
    ) -> GoogleOAuthAccountProfile? {
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            let descriptor = FetchDescriptor<GoogleOAuthAccountProfile>(predicate: #Predicate { $0.id == id })
            if let profile = (try? modelContext.fetch(descriptor))?.first {
                return profile
            }
        }

        let email = config.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let descriptor = FetchDescriptor<GoogleOAuthAccountProfile>(predicate: #Predicate { $0.email == email })
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func importedValidationConfiguration(
        strategy rawStrategy: String?,
        testCommand rawCommand: String?,
        workspacePath: String?
    ) -> (strategy: ValidationStrategy, testCommand: String) {
        let strategy = rawStrategy.flatMap(ValidationStrategy.init(rawValue:)) ?? .manual
        let command = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard strategy == .runTests else {
            return (strategy, command)
        }
        guard ValidationCommandPolicy.isRunTestsCommandAllowed(command, workspacePath: workspacePath) else {
            return (.runTests, "")
        }
        return (.runTests, command)
    }

    private static func linkSkills(
        to task: AgentTask,
        skillIDs: [String]?,
        legacySkillNames: [String],
        snapshots: [SkillSnapshotConfig],
        workspace: Workspace,
        modelContext: ModelContext,
        skillsByID: inout [String: Skill],
        skillsByName: inout [String: Skill],
        connectorsByID: inout [String: Connector],
        connectorsByName: inout [String: Connector],
        toolsByID: inout [String: LocalTool],
        toolsByName: inout [String: LocalTool]
    ) {
        let snapshotsByID = Dictionary(
            snapshots.compactMap { snapshot -> (String, SkillSnapshotConfig)? in
                guard let id = snapshot.id else { return nil }
                return (id, snapshot)
            },
            uniquingKeysWith: { first, _ in first }
        )

        if let skillIDs, !skillIDs.isEmpty {
            for id in skillIDs {
                if let skill = skillsByID[id] {
                    appendUnique(skill, to: &task.skills)
                    continue
                }
                if let snapshot = snapshotsByID[id] {
                    let restored = restoreSkill(
                        from: snapshot,
                        workspace: workspace,
                        modelContext: modelContext,
                        connectorsByID: &connectorsByID,
                        connectorsByName: &connectorsByName,
                        toolsByID: &toolsByID,
                        toolsByName: &toolsByName
                    )
                    skillsByID[restored.id.uuidString] = restored
                    if skillsByName[restored.name] == nil {
                        skillsByName[restored.name] = restored
                    }
                    appendUnique(restored, to: &task.skills)
                }
            }
        } else {
            for name in legacySkillNames {
                if let skill = skillsByName[name] {
                    appendUnique(skill, to: &task.skills)
                }
            }
        }
    }

    private static func restoreSkill(
        from snapshot: SkillSnapshotConfig,
        workspace: Workspace,
        modelContext: ModelContext,
        connectorsByID: inout [String: Connector],
        connectorsByName: inout [String: Connector],
        toolsByID: inout [String: LocalTool],
        toolsByName: inout [String: LocalTool]
    ) -> Skill {
        for connectorSnapshot in snapshot.connectorSnapshots ?? [] {
            guard let id = connectorSnapshot.id, connectorsByID[id] == nil else { continue }
            guard let connector = makeConnector(from: connectorSnapshot, workspace: workspace) else { continue }
            modelContext.insert(connector)
            connectorsByID[connector.id.uuidString] = connector
            if connectorsByName[connector.name] == nil {
                connectorsByName[connector.name] = connector
            }
        }
        for toolSnapshot in snapshot.localToolSnapshots ?? [] {
            guard let id = toolSnapshot.id, toolsByID[id] == nil else { continue }
            guard let tool = makeLocalTool(from: toolSnapshot, workspace: workspace) else { continue }
            modelContext.insert(tool)
            toolsByID[tool.id.uuidString] = tool
            if toolsByName[tool.name] == nil {
                toolsByName[tool.name] = tool
            }
        }

        let skill = makeRestoredSkill(from: snapshot, workspace: workspace)
        modelContext.insert(skill)
        linkResources(
            skill: skill,
            connectorIDs: snapshot.connectorIDs,
            connectorNames: nil,
            localToolIDs: snapshot.localToolIDs,
            localToolNames: nil,
            connectorsByID: connectorsByID,
            connectorsByName: connectorsByName,
            toolsByID: toolsByID,
            toolsByName: toolsByName
        )
        return skill
    }

    private static func appendUnique(_ skill: Skill, to skills: inout [Skill]) {
        guard !skills.contains(where: { $0.id == skill.id }) else { return }
        skills.append(skill)
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private static func importedActiveWorkingPath(
        _ activeWorkingPath: String?,
        primaryPath: String,
        additionalPaths: [String],
        fileManager: FileManager = .default
    ) -> String? {
        guard let active = activeWorkingPath,
              !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let activePath = WorkspacePathPresentation.standardizedPath(active)
        guard !activePath.isEmpty,
              isExistingDirectory(activePath, fileManager: fileManager),
              let canonicalActive = canonicalPath(activePath) else {
            return nil
        }

        let primary = WorkspacePathPresentation.standardizedPath(primaryPath)
        guard canonicalActive != canonicalPath(primary) else {
            return nil
        }

        let workspaceRootPaths = ([primaryPath] + additionalPaths)
            .map(WorkspacePathPresentation.standardizedPath)
            .filter { !$0.isEmpty }
        let canonicalWorkspaceRoots = workspaceRootPaths.compactMap(canonicalPath)

        if canonicalWorkspaceRoots.contains(where: { isPath(canonicalActive, insideOrEqualTo: $0) }) {
            return activePath
        }
        if isRegisteredWorktree(activePath, attachedTo: workspaceRootPaths, fileManager: fileManager) {
            return activePath
        }

        return nil
    }

    private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func canonicalPath(_ path: String) -> String? {
        ExecutionPathSafety.required.canonicalize(path)
    }

    private struct GitDirectoryLayout {
        public let gitDirectory: String
        public let commonDirectory: String
    }

    private static func isRegisteredWorktree(
        _ activePath: String,
        attachedTo workspaceRootPaths: [String],
        fileManager: FileManager
    ) -> Bool {
        guard let activeLayout = gitDirectoryLayout(for: activePath, fileManager: fileManager),
              worktreeAdminDirectory(activeLayout.gitDirectory, pointsBackTo: activePath, fileManager: fileManager) else {
            return false
        }

        return workspaceRootPaths.contains { rootPath in
            guard let rootLayout = gitDirectoryLayout(for: rootPath, fileManager: fileManager),
                  activeLayout.commonDirectory == rootLayout.commonDirectory else {
                return false
            }
            let worktreesDirectory = URL(fileURLWithPath: rootLayout.commonDirectory, isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
                .path
            return activeLayout.gitDirectory != activeLayout.commonDirectory
                && isPath(activeLayout.gitDirectory, insideOrEqualTo: worktreesDirectory)
        }
    }

    private static func gitDirectoryLayout(for path: String, fileManager: FileManager) -> GitDirectoryLayout? {
        guard let gitDirectory = gitDirectoryReference(for: path, fileManager: fileManager),
              isExistingDirectory(gitDirectory, fileManager: fileManager) else {
            return nil
        }
        let commonDirectory = commonGitDirectory(for: gitDirectory, fileManager: fileManager) ?? gitDirectory
        guard isExistingDirectory(commonDirectory, fileManager: fileManager) else {
            return nil
        }
        return GitDirectoryLayout(gitDirectory: gitDirectory, commonDirectory: commonDirectory)
    }

    private static func commonGitDirectory(for gitDirectory: String, fileManager: FileManager) -> String? {
        let commonDirPath = URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("commondir")
            .path
        guard let data = fileManager.contents(atPath: commonDirPath),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let resolved = value.hasPrefix("/")
            ? value
            : URL(fileURLWithPath: gitDirectory, isDirectory: true)
                .appendingPathComponent(value)
                .standardizedFileURL
                .path
        return canonicalPath(resolved)
    }

    private static func worktreeAdminDirectory(
        _ gitDirectory: String,
        pointsBackTo activePath: String,
        fileManager: FileManager
    ) -> Bool {
        let pointerPath = URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("gitdir")
            .path
        guard let data = fileManager.contents(atPath: pointerPath),
              let raw = String(data: data, encoding: .utf8) else {
            return false
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let resolved = value.hasPrefix("/")
            ? value
            : URL(fileURLWithPath: gitDirectory, isDirectory: true)
                .appendingPathComponent(value)
                .standardizedFileURL
                .path
        guard let canonicalGitFile = canonicalPath(resolved),
              let canonicalActive = canonicalPath(activePath) else {
            return false
        }
        let pointedWorktree = (canonicalGitFile as NSString).lastPathComponent == ".git"
            ? (canonicalGitFile as NSString).deletingLastPathComponent
            : canonicalGitFile
        return pointedWorktree == canonicalActive
    }

    private static func gitDirectoryReference(for path: String, fileManager: FileManager) -> String? {
        let gitPath = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(".git")
            .path
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return canonicalPath(gitPath)
        }
        guard let data = fileManager.contents(atPath: gitPath),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let prefix = "gitdir:"
        guard let line = text.split(whereSeparator: \.isNewline).first,
              line.lowercased().hasPrefix(prefix) else {
            return nil
        }
        let rawReference = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawReference.isEmpty else { return nil }
        let referencePath: String
        if rawReference.hasPrefix("/") {
            referencePath = rawReference
        } else {
            referencePath = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(rawReference)
                .standardizedFileURL
                .path
        }
        return canonicalPath(referencePath)
    }

    private static func isPath(_ path: String, insideOrEqualTo root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty else { return false }
        if root == "/" {
            return path.hasPrefix("/")
        }
        return path == root || path.hasPrefix(root + "/")
    }
}

/// Serializes workspace auto-export JSON encode + file writes off the main actor.
///
/// Actor isolation guarantees that two auto-exports never write the same file
/// concurrently, and the `.atomic` write means `WorkspaceRecoveryService` /
/// `loadConfig` can never observe a torn file. Auto-export drops `.prettyPrinted`
/// (kept only for explicit user-facing exports via `WorkspaceConfigManager.write`)
/// while preserving `.sortedKeys` so the on-disk recovery file stays deterministic.
actor WorkspaceAutoExportWriter {
    static let shared = WorkspaceAutoExportWriter()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func write(
        _ config: WorkspaceConfigManager.WorkspaceConfig,
        to url: URL,
        workspaceID: String
    ) {
        do {
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            let nsError = error as NSError
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_failed",
                "diagnostic_result": "writeFailed",
                "workspace_id": workspaceID,
                "config_file": url.lastPathComponent,
                "path": url.path,
                "error_type": String(describing: type(of: error)),
                "error_domain": nsError.domain,
                "error_code": String(nsError.code),
                "error_description": nsError.localizedDescription
            ], level: .error)
        }
    }
}
