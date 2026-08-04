import Foundation
import ASTRAModels

/// Applies the immutable launch configuration captured by a durable request.
/// The queue uses a detached value/task view for the lifetime of one dispatch.
/// The live SwiftData task remains the editable durable source of truth and is
/// never temporarily rewritten with request-time values.
@MainActor
enum TaskExecutionLaunchSnapshotApplicator {
    /// Legacy V15 requests have no complete snapshot and intentionally keep
    /// their historical live-task behavior. A malformed V16 policy also fails
    /// closed without partially applying a mixed launch configuration.
    static func snapshot(request: TaskTurnRequest, from task: AgentTask) -> AgentTaskLaunchSnapshot? {
        guard let runtimeID = request.runtimeIDSnapshot,
              let model = request.modelSnapshot,
              let tokenBudget = request.tokenBudgetSnapshot,
              let policy = request.executionPolicySnapshot,
              IsolationStrategy(rawValue: policy.isolationStrategyRawValue) != nil,
              ValidationStrategy(rawValue: policy.validationStrategyRawValue) != nil else {
            return nil
        }
        return AgentTaskLaunchSnapshot(
            id: task.id,
            model: model,
            maxTurns: policy.maxTurns,
            runtimeID: runtimeID,
            runtimeExplicitlySelected: policy.runtimeExplicitlySelected,
            tokenBudget: tokenBudget,
            isolationStrategy: IsolationStrategy(rawValue: policy.isolationStrategyRawValue) ?? .sameDirectory,
            validationStrategy: ValidationStrategy(rawValue: policy.validationStrategyRawValue) ?? .manual,
            testCommand: policy.testCommand,
            useAgentTeam: policy.useAgentTeam,
            teamSize: policy.teamSize,
            teamInstructions: policy.teamInstructions,
            executionRootPath: policy.executionRootPath,
            executionEnvironmentSnapshotJSON: policy.executionEnvironmentSnapshotJSON,
            templateHooksJSON: policy.templateHooksJSON,
            skillSnapshotsJSON: policy.skillSnapshotsJSON,
            runtimePermissionGrantsJSON: policy.runtimePermissionGrantsJSON
        )
    }

    /// An unmanaged task view lets existing launch planners consume the same
    /// task-shaped interface without giving them a writable SwiftData object.
    static func detachedTask(_ snapshot: AgentTaskLaunchSnapshot, from source: AgentTask) -> AgentTask {
        let resolvedInventory = TaskCapabilityResolver(task: source).resourceInventory
        let cloneSources = capabilityCloneSources(source: source, resolvedInventory: resolvedInventory)
        let workspace = source.workspace.map(detachedWorkspace)
        let capabilityGraph = detachedCapabilityGraph(
            sources: cloneSources,
            workspace: workspace
        )
        let task = AgentTask(title: source.title, goal: source.goal, workspace: workspace)
        task.id = source.id
        task.inputs = source.inputs
        task.constraints = source.constraints
        task.acceptanceCriteria = source.acceptanceCriteria
        task.isolationStrategy = snapshot.isolationStrategy
        task.validationStrategy = snapshot.validationStrategy
        task.tokenBudget = snapshot.tokenBudget
        task.tokensUsed = source.tokensUsed
        task.model = snapshot.model
        task.runtimeID = snapshot.runtimeID
        task.runtimeExplicitlySelected = snapshot.runtimeExplicitlySelected
        task.testCommand = snapshot.testCommand
        task.costUSD = source.costUSD
        task.queuePosition = source.queuePosition
        task.sessionId = source.sessionId
        task.chainedGoal = source.chainedGoal
        task.chainedFromID = source.chainedFromID
        task.forkedFromID = source.forkedFromID
        task.forkedAtRunIndex = source.forkedAtRunIndex
        task.draftMessages = source.draftMessages
        task.maxTurns = snapshot.maxTurns
        task.useAgentTeam = snapshot.useAgentTeam
        task.teamSize = snapshot.teamSize
        task.teamInstructions = snapshot.teamInstructions
        task.templateID = source.templateID
        task.templateHooksJSON = snapshot.templateHooksJSON
        task.originScheduleID = source.originScheduleID
        task.skillSnapshotsJSON = snapshot.skillSnapshotsJSON
        task.isPinned = source.isPinned
        task.isDone = source.isDone
        task.unreadAt = source.unreadAt
        task.executionRootPath = snapshot.executionRootPath
        task.executionEnvironmentSnapshotJSON = snapshot.executionEnvironmentSnapshotJSON
        task.runtimePermissionOpenRequestsJSON = source.runtimePermissionOpenRequestsJSON
        task.runtimePermissionGrantsJSON = snapshot.runtimePermissionGrantsJSON
        task.rememberedWorkspaceCanvasItemRawValue = source.rememberedWorkspaceCanvasItemRawValue
        task.createdAt = source.createdAt
        task.updatedAt = source.updatedAt
        task.completedAt = source.completedAt
        let detachedRuns = source.runs.map { detachedRun($0, task: task) }
        let runByID = Dictionary(uniqueKeysWithValues: detachedRuns.map { ($0.id, $0) })
        task.runs = detachedRuns
        task.events = source.events.map { detachedEvent($0, task: task, runs: runByID) }
        task.artifacts = source.artifacts.map { detachedArtifact($0, task: task) }
        task.skills = source.skills.map {
            capabilityGraph.skillsByID[$0.id] ?? detachedSkill($0)
        }
        return task
    }

    private struct CapabilityCloneSources {
        let skills: [Skill]
        let connectors: [Connector]
        let localTools: [LocalTool]
        let workspaceSkillIDs: Set<UUID>
        let workspaceConnectorIDs: Set<UUID>
        let workspaceLocalToolIDs: Set<UUID>
    }

    private struct DetachedCapabilityGraph {
        let skillsByID: [UUID: Skill]
    }

    /// The live workspace remains authoritative for capability enablement. At
    /// dispatch, project exactly its resolved inventory into the unmanaged
    /// launch graph so later planners do not need a SwiftData ModelContext.
    private static func capabilityCloneSources(
        source: AgentTask,
        resolvedInventory: TaskCapabilityResolver.ResourceInventory
    ) -> CapabilityCloneSources {
        let workspaceSkills = source.workspace?.skills ?? []
        let workspaceConnectors = source.workspace?.connectors ?? []
        let workspaceLocalTools = source.workspace?.localTools ?? []

        var skills = uniqueSkills(
            workspaceSkills + source.skills + resolvedInventory.behaviorSkills
        )
        var connectors = uniqueConnectors(
            workspaceConnectors +
                (workspaceSkills + source.skills).flatMap(\.connectors) +
                resolvedInventory.connectors
        )
        var localTools = uniqueLocalTools(
            workspaceLocalTools +
                (workspaceSkills + source.skills).flatMap(\.localTools) +
                resolvedInventory.localTools
        )

        skills = uniqueSkills(
            skills + connectors.compactMap(\.skill) + localTools.compactMap(\.skill)
        )
        connectors = uniqueConnectors(connectors)
        localTools = uniqueLocalTools(localTools)

        return CapabilityCloneSources(
            skills: skills,
            connectors: connectors,
            localTools: localTools,
            workspaceSkillIDs: Set(
                (workspaceSkills + resolvedInventory.behaviorSkills).map(\.id)
            ),
            workspaceConnectorIDs: Set(
                (workspaceConnectors + resolvedInventory.connectors).map(\.id)
            ),
            workspaceLocalToolIDs: Set(
                (workspaceLocalTools + resolvedInventory.localTools).map(\.id)
            )
        )
    }

    /// Clone first, then wire only clones. This keeps every UUID represented by
    /// one launch object and prevents inverse relationships from touching the
    /// managed source graph.
    private static func detachedCapabilityGraph(
        sources: CapabilityCloneSources,
        workspace: Workspace?
    ) -> DetachedCapabilityGraph {
        let skills = sources.skills.map(detachedSkill)
        let skillsByID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        let connectors = sources.connectors.map { source in
            detachedConnector(source, skill: source.skill.flatMap { skillsByID[$0.id] })
        }
        let localTools = sources.localTools.map { source in
            detachedLocalTool(source, skill: source.skill.flatMap { skillsByID[$0.id] })
        }

        if let workspace {
            workspace.skills = skills.filter { sources.workspaceSkillIDs.contains($0.id) }
            workspace.connectors = connectors.filter {
                sources.workspaceConnectorIDs.contains($0.id)
            }
            workspace.localTools = localTools.filter {
                sources.workspaceLocalToolIDs.contains($0.id)
            }
        }

        return DetachedCapabilityGraph(skillsByID: skillsByID)
    }

    private static func detachedWorkspace(_ source: Workspace) -> Workspace {
        let workspace = Workspace(
            name: source.name,
            primaryPath: source.primaryPath,
            additionalPaths: source.additionalPaths,
            icon: source.icon,
            instructions: source.instructions
        )
        workspace.id = source.id
        workspace.lastUsedSkillNames = source.lastUsedSkillNames
        workspace.enabledGlobalSkillIDs = source.enabledGlobalSkillIDs
        workspace.enabledGlobalConnectorIDs = source.enabledGlobalConnectorIDs
        workspace.enabledGlobalToolIDs = source.enabledGlobalToolIDs
        workspace.enabledCapabilityIDs = source.enabledCapabilityIDs
        workspace.enabledPackIDs = source.enabledPackIDs
        workspace.shelfVisibilityOverrideIDs = source.shelfVisibilityOverrideIDs
        workspace.shelfVisibilityOverrideValues = source.shelfVisibilityOverrideValues
        workspace.memories = source.memories
        workspace.installedPluginIDs = source.installedPluginIDs
        workspace.installedPluginVersions = source.installedPluginVersions
        workspace.isStarred = source.isStarred
        workspace.activeWorkingPath = source.activeWorkingPath
        workspace.activeExecutionEnvironmentJSON = source.activeExecutionEnvironmentJSON
        workspace.createdAt = source.createdAt
        workspace.updatedAt = source.updatedAt
        return workspace
    }

    private static func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        var seen = Set<UUID>()
        return skills.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return connectors.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueLocalTools(_ localTools: [LocalTool]) -> [LocalTool] {
        var seen = Set<UUID>()
        return localTools.filter { seen.insert($0.id).inserted }
    }

    private static func detachedRun(_ source: TaskRun, task: AgentTask) -> TaskRun {
        let run = TaskRun(task: task)
        run.id = source.id
        // This is an unmanaged history copy, not a durable task transition.
        run[keyPath: \.status] = source.status
        run.startedAt = source.startedAt
        run.completedAt = source.completedAt
        run.tokensUsed = source.tokensUsed
        run.inputTokens = source.inputTokens
        run.outputTokens = source.outputTokens
        run.runtimeID = source.runtimeID
        run.providerSessionId = source.providerSessionId
        run.providerVersion = source.providerVersion
        run.executionEnvironmentSnapshotJSON = source.executionEnvironmentSnapshotJSON
        run.providerLaunchSignatureJSON = source.providerLaunchSignatureJSON
        run.exitCode = source.exitCode
        run.output = source.output
        run.costUSD = source.costUSD
        run.fileChangesJSON = source.fileChangesJSON
        run.stopReason = source.stopReason
        return run
    }

    private static func detachedEvent(
        _ source: TaskEvent,
        task: AgentTask,
        runs: [UUID: TaskRun]
    ) -> TaskEvent {
        let event = TaskEvent(
            task: task,
            type: source.type,
            payload: source.payload,
            run: source.run.flatMap { runs[$0.id] }
        )
        event.id = source.id
        event.timestamp = source.timestamp
        event.agentName = source.agentName
        event.agentId = source.agentId
        event.teamName = source.teamName
        event.category = source.category
        return event
    }

    private static func detachedArtifact(_ source: Artifact, task: AgentTask) -> Artifact {
        let artifact = Artifact(task: task, type: source.type, path: source.path, content: source.content, version: source.version)
        artifact.id = source.id
        artifact.createdAt = source.createdAt
        return artifact
    }

    private static func detachedSkill(_ source: Skill) -> Skill {
        let skill = Skill(
            name: source.name,
            icon: source.icon,
            skillDescription: source.skillDescription,
            allowedTools: source.allowedTools,
            disallowedTools: source.disallowedTools,
            customTools: source.customTools,
            behaviorInstructions: source.behaviorInstructions
        )
        skill.id = source.id
        skill.environmentKeys = source.environmentKeys
        skill.environmentValues = source.environmentValues
        skill.originPackageID = source.originPackageID
        skill.originPackageVersion = source.originPackageVersion
        skill.originComponentID = source.originComponentID
        skill.originComponentKind = source.originComponentKind
        skill.originSourceKind = source.originSourceKind
        skill.createdAt = source.createdAt
        skill.updatedAt = source.updatedAt
        skill.isGlobal = source.isGlobal
        skill.isBuiltIn = source.isBuiltIn
        return skill
    }

    private static func detachedConnector(
        _ source: Connector,
        workspace: Workspace? = nil,
        skill: Skill? = nil
    ) -> Connector {
        let connector = Connector(
            name: source.name,
            serviceType: source.serviceType,
            icon: source.icon,
            connectorDescription: source.connectorDescription,
            baseURL: source.baseURL,
            authMethod: source.authMethod
        )
        connector.id = source.id
        connector.credentialKeys = source.credentialKeys
        connector.credentialValues = source.credentialValues
        connector.configKeys = source.configKeys
        connector.configValues = source.configValues
        connector.isGlobal = source.isGlobal
        connector.testHTTPMethod = source.testHTTPMethod
        connector.notes = source.notes
        connector.originPackageID = source.originPackageID
        connector.originPackageVersion = source.originPackageVersion
        connector.originComponentID = source.originComponentID
        connector.originComponentKind = source.originComponentKind
        connector.originSourceKind = source.originSourceKind
        connector.createdAt = source.createdAt
        connector.updatedAt = source.updatedAt
        connector.workspace = workspace
        connector.skill = skill
        return connector
    }

    private static func detachedLocalTool(
        _ source: LocalTool,
        workspace: Workspace? = nil,
        skill: Skill? = nil
    ) -> LocalTool {
        let tool = LocalTool(
            name: source.name,
            toolDescription: source.toolDescription,
            icon: source.icon,
            toolType: source.toolType,
            command: source.command,
            arguments: source.arguments
        )
        tool.id = source.id
        tool.isGlobal = source.isGlobal
        tool.originPackageID = source.originPackageID
        tool.originPackageVersion = source.originPackageVersion
        tool.originComponentID = source.originComponentID
        tool.originComponentKind = source.originComponentKind
        tool.originSourceKind = source.originSourceKind
        tool.createdAt = source.createdAt
        tool.updatedAt = source.updatedAt
        tool.workspace = workspace
        tool.skill = skill
        return tool
    }
}
