import Foundation
import SwiftData
import ASTRACore
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
            reasoningEffort: policy.reasoningEffort,
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
            runtimePermissionGrantsJSON: policy.runtimePermissionGrantsJSON,
            pluginActivations: policy.pluginActivations,
            pluginDefinitions: policy.pluginDefinitions,
            pluginAccounts: policy.pluginAccounts,
            pluginOverrides: policy.pluginOverrides,
            retiredPluginActivations: policy.retiredPluginActivations
        )
    }

    /// An unmanaged task view lets existing launch planners consume the same
    /// task-shaped interface without giving them a writable SwiftData object.
    static func detachedTask(_ snapshot: AgentTaskLaunchSnapshot, from source: AgentTask) -> AgentTask {
        let resolvedInventory = TaskCapabilityResolver(task: source).resourceInventory
        let cloneSources = capabilityCloneSources(
            source: source,
            resolvedInventory: resolvedInventory,
            frozen: frozenRows(of: snapshot, source: source),
            unfrozenAccountIDs: unfrozenAccountIDs(of: snapshot, source: source)
        )
        let workspace = source.workspace.map(detachedWorkspace)
        let capabilityGraph = detachedCapabilityGraph(
            sources: cloneSources,
            workspace: workspace
        )
        if let workspace, let live = source.workspace {
            // The accounts and definitions frozen with them: an account
            // edited or deleted, or a plugin updated, while the request
            // waited does not change the run either.
            applyFrozenAccounts(snapshot.pluginAccounts, to: workspace)
            // So are the override rows' contents: an override edited or
            // deleted while it waited runs as submitted.
            var lateAttachments = LateAttachments()
            let frozenRowIDs = applyFrozenOverrides(
                snapshot.pluginOverrides, to: workspace, skillsByID: capabilityGraph.skillsByID, unlinked: &lateAttachments
            )
            pruneLateAttachments(lateAttachments, of: snapshot, from: workspace, keeping: frozenRowIDs)
            workspace.launchPluginDefinitions = snapshot.pluginDefinitions
            // The activations frozen at submission, when the request has
            // them: a plugin turned off, on or reconfigured while it waited
            // does not change the run.
            WorkspaceCapabilityActivation.copyActivations(
                snapshot.pluginActivations ?? WorkspaceCapabilityActivation.activations(of: live).map(PluginActivationRecord.init),
                of: live,
                to: workspace,
                accountsByID: Dictionary(workspace.connectors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                frozenRowIDs: frozenRowIDs
            )
            // With the record of removed ones: the rows a Remove kept out of
            // scope at submission stay out, even if the plugin was added back.
            WorkspaceCapabilityActivation.applyFrozenRetired(snapshot.retiredPluginActivations, to: workspace)
        }
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
        task.reasoningEffort = snapshot.reasoningEffort
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

    /// Unmanaged copies of `skills`, with their own connectors and local tools
    /// wired to the copies. A composer projection must never relate an
    /// unmanaged task to a managed skill: assigning one to `AgentTask.skills`
    /// updates the skill's inverse `tasks`, which makes SwiftData adopt the
    /// projection and persist it as a phantom draft on the next save.
    static func detachedSkills(_ skills: [Skill]) -> [Skill] {
        let skills = uniqueSkills(skills)
        let connectors = uniqueConnectors(skills.flatMap(\.connectors))
        let localTools = uniqueLocalTools(skills.flatMap(\.localTools))
        let graph = detachedCapabilityGraph(
            sources: CapabilityCloneSources(
                skills: skills,
                connectors: connectors,
                localTools: localTools,
                workspaceSkillIDs: [],
                workspaceConnectorIDs: [],
                workspaceLocalToolIDs: []
            ),
            workspace: nil
        )
        // The resolver keeps a non-global skill connector only when its
        // workspace id matches the task's, so the copies keep that ownership —
        // through an unmanaged workspace projection, never the managed one.
        var workspaceProjections: [UUID: Workspace] = [:]
        func projection(of source: Workspace?) -> Workspace? {
            guard let source else { return nil }
            if let existing = workspaceProjections[source.id] { return existing }
            let workspace = detachedWorkspace(source)
            workspaceProjections[source.id] = workspace
            return workspace
        }
        let connectorWorkspaces = Dictionary(
            connectors.map { ($0.id, $0.workspace) },
            uniquingKeysWith: { first, _ in first }
        )
        let localToolWorkspaces = Dictionary(
            localTools.map { ($0.id, $0.workspace) },
            uniquingKeysWith: { first, _ in first }
        )
        for skill in graph.skillsByID.values {
            for connector in skill.connectors {
                connector.workspace = projection(of: connectorWorkspaces[connector.id] ?? nil)
            }
            for tool in skill.localTools {
                tool.workspace = projection(of: localToolWorkspaces[tool.id] ?? nil)
            }
        }
        return skills.compactMap { graph.skillsByID[$0.id] }
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

    /// Rows the frozen activations name: the accounts they bind and the
    /// authored rows that replaced a component.
    private struct FrozenActivationRows {
        var accounts: [Connector] = []
        var skills: [Skill] = []
        var localTools: [LocalTool] = []
    }

    /// The rows the frozen activations name that the live inventory may no
    /// longer reach (a shared account or edited shared skill of a plugin
    /// turned off since), so the launch copy resolves them as submitted. A
    /// request that froze its override rows' contents never reads them live.
    private static func frozenRows(of snapshot: AgentTaskLaunchSnapshot, source: AgentTask) -> FrozenActivationRows {
        guard let records = snapshot.pluginActivations?.filter(\.isEnabled),
              let context = source.modelContext ?? source.workspace?.modelContext else { return FrozenActivationRows() }
        let accountIDs = Array(Set(records.flatMap(\.bindings).compactMap(\.accountID)))
        let rowIDs = Array(Set(records.flatMap(\.overridingRowIDs).compactMap(UUID.init(uuidString:))))
        var rows = FrozenActivationRows()
        if !accountIDs.isEmpty {
            let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { accountIDs.contains($0.id) })
            rows.accounts = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isDeleted }
        }
        if !rowIDs.isEmpty, snapshot.pluginOverrides == nil {
            let skills = FetchDescriptor<Skill>(predicate: #Predicate { rowIDs.contains($0.id) })
            rows.skills = ((try? context.fetch(skills)) ?? []).filter { !$0.isDeleted }
            let tools = FetchDescriptor<LocalTool>(predicate: #Predicate { rowIDs.contains($0.id) })
            rows.localTools = ((try? context.fetch(tools)) ?? []).filter { !$0.isDeleted }
        }
        return rows
    }

    /// The accounts the live workspace's activations bind that no frozen
    /// activation does: a plugin added, or an account bound, while the
    /// request waited. Who owns an account is frozen with the activations,
    /// so these stay out of the launch copy, where nothing would bind them
    /// and they would read as the workspace's own (`TaskCapabilityResolver`
    /// scopes an unbound workspace account). Empty for a request that froze
    /// no activations: its launch copy binds the live ones.
    private static func unfrozenAccountIDs(of snapshot: AgentTaskLaunchSnapshot, source: AgentTask) -> Set<UUID> {
        guard let records = snapshot.pluginActivations, let live = source.workspace else { return [] }
        let frozen = Set(records.flatMap(\.bindings).compactMap(\.accountID))
        let bound = WorkspaceCapabilityActivation.activations(of: live)
            .flatMap(\.bindings)
            .filter { !$0.isDeleted }
            .compactMap { $0.account?.id }
        return Set(bound).subtracting(frozen)
    }

    /// The bound accounts' copies take the contents frozen at submission;
    /// one deleted since is brought back as a copy of what was submitted.
    /// Credentials are still read from the Keychain by the account's ID.
    private static func applyFrozenAccounts(_ records: [PluginAccountRecord]?, to workspace: Workspace) {
        for record in records ?? [] {
            if let copy = workspace.connectors.first(where: { $0.id == record.id }) {
                record.apply(to: copy)
            } else {
                workspace.connectors.append(record.makeAccount())
            }
        }
    }

    /// The override rows' copies take the contents frozen at submission; one
    /// deleted since, or out of the live inventory, is brought back as a copy
    /// of what was submitted. Secret settings are still read from the
    /// Keychain by the row's ID. Returns the frozen rows' IDs.
    private static func applyFrozenOverrides(
        _ records: PluginOverrideRecords?,
        to workspace: Workspace,
        skillsByID: [UUID: Skill],
        unlinked: inout LateAttachments
    ) -> Set<UUID> {
        guard let records else { return [] }
        var skills = skillsByID
        for record in records.skills {
            let copy = workspace.skills.first { $0.id == record.id } ?? skills[record.id] ?? record.makeSkill()
            record.apply(to: copy)
            if !workspace.skills.contains(where: { $0 === copy }) { workspace.skills.append(copy) }
            skills[record.id] = copy
            applyFrozenAttachments(of: record, to: copy, in: workspace, unlinked: &unlinked)
        }
        for record in records.localTools {
            let copy = workspace.localTools.first { $0.id == record.id }
                ?? skills.values.lazy.flatMap(\.localTools).first { $0.id == record.id }
                ?? record.makeTool()
            record.apply(to: copy)
            copy.skill = record.skillID.flatMap { skills[$0] }
            if !workspace.localTools.contains(where: { $0 === copy }) { workspace.localTools.append(copy) }
        }
        return records.rowIDs
    }

    /// An override skill's copy carries exactly the attachments frozen with
    /// it, as submitted: one edited since takes its submitted contents, one
    /// deleted since is brought back, one attached since is left off. A
    /// request recorded before attachments were frozen keeps the live ones.
    private static func applyFrozenAttachments(
        of record: PluginOverrideRecords.SkillRecord,
        to skill: Skill,
        in workspace: Workspace,
        unlinked: inout LateAttachments
    ) {
        if let connectorRecords = record.attachedConnectors {
            let frozenIDs = Set(connectorRecords.map(\.id))
            unlinked.connectorIDs.formUnion(skill.connectors.map(\.id).filter { !frozenIDs.contains($0) })
            skill.connectors = connectorRecords.map { attached in
                let existing = skill.connectors.first { $0.id == attached.id }
                    ?? workspace.connectors.first { $0.id == attached.id }
                let copy = existing ?? attached.makeAccount()
                attached.apply(to: copy)
                if existing == nil, !attached.isGlobal { copy.workspace = workspace }
                copy.skill = skill
                return copy
            }
        }
        if let toolRecords = record.attachedTools {
            let frozenIDs = Set(toolRecords.map(\.id))
            unlinked.toolIDs.formUnion(skill.localTools.map(\.id).filter { !frozenIDs.contains($0) })
            skill.localTools = toolRecords.map { attached in
                let existing = skill.localTools.first { $0.id == attached.id }
                    ?? workspace.localTools.first { $0.id == attached.id }
                let copy = existing ?? attached.makeTool()
                attached.apply(to: copy)
                if existing == nil, !attached.isGlobal { copy.workspace = workspace }
                copy.skill = skill
                return copy
            }
        }
    }

    /// Drops from the launch workspace the copies of rows `unlinked` names:
    /// attached to an override skill live but not in its frozen attachments
    /// (attached after submission). A connector or tool belongs to one skill,
    /// so the live store had it only as that skill's attachment; left in the
    /// copy unlinked, it would read as the workspace's own. Kept: an account
    /// a frozen activation binds, an override row itself, and a shared row
    /// the workspace lists on its own.
    private static func pruneLateAttachments(
        _ unlinked: LateAttachments,
        of snapshot: AgentTaskLaunchSnapshot,
        from workspace: Workspace,
        keeping frozenRowIDs: Set<UUID>
    ) {
        guard !unlinked.connectorIDs.isEmpty || !unlinked.toolIDs.isEmpty else { return }
        // One another frozen override still has attached is its row there.
        let records = snapshot.pluginOverrides?.skills ?? []
        let frozenConnectors = Set(records.flatMap { $0.attachedConnectors?.map(\.id) ?? [] })
        let frozenTools = Set(records.flatMap { $0.attachedTools?.map(\.id) ?? [] })
        let bound = Set((snapshot.pluginActivations ?? []).flatMap(\.bindings).compactMap(\.accountID))
            .union((snapshot.pluginAccounts ?? []).map(\.id))
            .union(frozenConnectors)
        let state = WorkspaceCapabilityActivation.state(of: workspace)
        let listedConnectors = Set(state.globalConnectorIDs)
        let listedTools = Set(state.globalToolIDs)
        workspace.connectors.removeAll { connector in
            unlinked.connectorIDs.contains(connector.id) && !bound.contains(connector.id)
                && !frozenRowIDs.contains(connector.id)
                && !(connector.isGlobal && listedConnectors.contains(connector.id.uuidString))
        }
        workspace.localTools.removeAll { tool in
            unlinked.toolIDs.contains(tool.id) && !frozenRowIDs.contains(tool.id) && !frozenTools.contains(tool.id)
                && !(tool.isGlobal && listedTools.contains(tool.id.uuidString))
        }
    }

    /// The live attachments the frozen override records left off.
    private struct LateAttachments {
        var connectorIDs = Set<UUID>()
        var toolIDs = Set<UUID>()
    }

    /// The definitions a request should freeze for `task`: a launch copy's
    /// own frozen ones, else the library's for the plugins its workspace has
    /// on. The run's policy gates still apply at launch.
    static func pluginDefinitions(for task: AgentTask) -> [PluginPackage]? {
        guard let workspace = task.workspace else { return nil }
        if let frozen = workspace.launchPluginDefinitions { return frozen }
        let enabled = Set(WorkspaceCapabilityActivation.enabledPluginIDs(of: workspace))
        guard !enabled.isEmpty else { return [] }
        return CapabilityRuntimeResourceMatcher.packageDefinitions().filter { enabled.contains($0.id) }
    }

    /// The live workspace remains authoritative for capability enablement
    /// other than plugin activations, which a request freezes at submission.
    /// At dispatch, project exactly its resolved inventory (and the frozen
    /// activations' accounts) into the unmanaged launch graph so later
    /// planners do not need a SwiftData ModelContext.
    private static func capabilityCloneSources(
        source: AgentTask,
        resolvedInventory: TaskCapabilityResolver.ResourceInventory,
        frozen: FrozenActivationRows = FrozenActivationRows(),
        unfrozenAccountIDs: Set<UUID> = []
    ) -> CapabilityCloneSources {
        let workspaceSkills = source.workspace?.skills ?? []
        let workspaceConnectors = source.workspace?.connectors ?? []
        let workspaceLocalTools = source.workspace?.localTools ?? []

        var skills = uniqueSkills(
            workspaceSkills + source.skills + resolvedInventory.behaviorSkills + frozen.skills
        )
        var connectors = uniqueConnectors(
            workspaceConnectors +
                (workspaceSkills + source.skills).flatMap(\.connectors) +
                resolvedInventory.connectors +
                frozen.accounts
        )
        var localTools = uniqueLocalTools(
            workspaceLocalTools +
                (workspaceSkills + source.skills).flatMap(\.localTools) +
                resolvedInventory.localTools +
                frozen.localTools
        )

        connectors.removeAll { unfrozenAccountIDs.contains($0.id) }
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
                (workspaceSkills + resolvedInventory.behaviorSkills + frozen.skills).map(\.id)
            ),
            workspaceConnectorIDs: Set(
                (workspaceConnectors + resolvedInventory.connectors + frozen.accounts).map(\.id)
            ),
            workspaceLocalToolIDs: Set(
                (workspaceLocalTools + resolvedInventory.localTools + frozen.localTools).map(\.id)
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
        // Plugin activations are copied whole once the launch graph exists,
        // so their bindings can point at its account copies.
        var state = WorkspaceCapabilityActivation.state(of: source)
        state.capabilityIDs = []
        state.pluginIDs = []
        state.pluginVersions = []
        WorkspaceCapabilityActivation.apply(state, to: workspace)
        WorkspaceCapabilityActivation.copyRetired(from: source, to: workspace)
        WorkspaceCapabilityActivation.copyPendingLegacyEnablement(from: source, to: workspace)
        workspace.shelfVisibilityOverrideIDs = source.shelfVisibilityOverrideIDs
        workspace.shelfVisibilityOverrideValues = source.shelfVisibilityOverrideValues
        workspace.memories = source.memories
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
        run.setOutput(source.output)
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

    nonisolated static func detachedSkill(_ source: Skill) -> Skill {
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

    nonisolated static func detachedConnector(
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

    nonisolated static func detachedLocalTool(
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
