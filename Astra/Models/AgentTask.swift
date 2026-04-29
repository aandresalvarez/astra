import Foundation
import SwiftData
import ASTRACore

enum TaskStatus: String, Codable, CaseIterable {
    case draft
    case queued
    case running
    case pendingUser = "pending_user"
    case completed
    case failed
    case cancelled
    case budgetExceeded = "budget_exceeded"
}

enum IsolationStrategy: String, Codable, CaseIterable {
    case sameDirectory = "same_directory"
    case gitBranch = "git_branch"
    case copy
}

enum ValidationStrategy: String, Codable, CaseIterable {
    case manual
    case runTests = "run_tests"
    case aiCheck = "ai_check"
}

@Model
final class AgentTask {
    struct ToolPermissionConflict: Equatable {
        let tool: String
        let allowedBy: String
        let disallowedBy: String
    }

    var id: UUID
    var title: String
    var goal: String
    var inputs: [String]
    var constraints: [String]
    var acceptanceCriteria: [String]
    var status: TaskStatus
    var workspace: Workspace?
    var isolationStrategy: IsolationStrategy
    var validationStrategy: ValidationStrategy
    var tokenBudget: Int
    var tokensUsed: Int
    var model: String
    var testCommand: String
    var costUSD: Double
    var queuePosition: Int
    var sessionId: String?
    var chainedGoal: String          // If set, auto-creates a follow-up task on completion
    var chainedFromID: UUID?         // ID of the task that spawned this one
    var forkedFromID: UUID?          // ID of the source task this was forked from
    var forkedAtRunIndex: Int        // Index of the run at the fork point (0-based)
    var draftMessages: String        // JSON-encoded conversation for draft tasks
    var maxTurns: Int               // 0 = unlimited
    // Agent Teams
    var useAgentTeam: Bool
    var teamSize: Int
    var teamInstructions: String
    var templateID: UUID?          // TaskTemplate this task was created from
    var templateHooksJSON: String   // Hooks to inject during execution (from template)
    var originScheduleID: UUID?    // Schedule that spawned this task (for result routing)
    var skillSnapshotsJSON: String  // JSON-encoded task-time skill definitions for durable history
    var isPinned: Bool
    var isDone: Bool
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \TaskRun.task)
    var runs: [TaskRun] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskEvent.task)
    var events: [TaskEvent] = []

    @Relationship(deleteRule: .cascade, inverse: \Artifact.task)
    var artifacts: [Artifact] = []

    @Relationship
    var skills: [Skill] = []

    var effectiveWorkspacePath: String {
        workspace?.primaryPath ?? ""
    }

    /// The directory where the Claude CLI process should actually run.
    /// Prefers the first additional path (where the actual code lives) over the
    /// Astra workspace folder (which is for metadata/task outputs).
    var codeWorkingDirectory: String {
        if let first = workspace?.additionalPaths.first,
           !first.isEmpty,
           FileManager.default.fileExists(atPath: first) {
            return first
        }
        return effectiveWorkspacePath
    }

    /// Per-task subfolder within the workspace for task-specific outputs
    var taskFolder: String {
        WorkspaceFileLayout.readableTaskFolder(workspacePath: effectiveWorkspacePath, taskID: id)
    }

    var canonicalTaskFolder: String {
        WorkspaceFileLayout.taskFolder(workspacePath: effectiveWorkspacePath, taskID: id)
    }

    /// Ensures the task folder exists on disk, creating it if needed.
    /// Throws if the directory cannot be created.
    @discardableResult
    func ensureTaskFolder(fileSystem: FileSystem = RealFileSystem()) throws -> String {
        let path = WorkspaceFileLayout.migrateLegacyTaskFolderIfNeeded(
            workspacePath: effectiveWorkspacePath,
            taskID: id
        )
        guard !path.isEmpty else {
            AppLogger.audit(.taskFailed, category: "General", taskID: id, fields: [
                "reason": "task_folder_empty_path"
            ], level: .error)
            return ""
        }
        try fileSystem.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        return path
    }

    init(
        title: String,
        goal: String,
        workspace: Workspace? = nil,
        tokenBudget: Int = 50000,
        model: String = "claude-sonnet-4-6",
        isolationStrategy: IsolationStrategy = .sameDirectory,
        validationStrategy: ValidationStrategy = .manual
    ) {
        self.id = UUID()
        self.title = title
        self.goal = goal
        self.inputs = []
        self.constraints = []
        self.acceptanceCriteria = []
        self.status = .draft
        self.workspace = workspace
        self.isolationStrategy = isolationStrategy
        self.validationStrategy = validationStrategy
        self.tokenBudget = tokenBudget
        self.tokensUsed = 0
        self.model = model
        self.testCommand = ""
        self.costUSD = 0
        self.queuePosition = 0
        self.chainedGoal = ""
        self.forkedAtRunIndex = 0
        self.draftMessages = ""
        self.maxTurns = 0
        self.useAgentTeam = false
        self.teamSize = 3
        self.teamInstructions = ""
        self.templateHooksJSON = ""
        self.skillSnapshotsJSON = "[]"
        self.isPinned = false
        self.isDone = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var skillSnapshots: [SkillSnapshotConfig] {
        get {
            guard let data = skillSnapshotsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([SkillSnapshotConfig].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            skillSnapshotsJSON = json
        }
    }

    func captureSkillSnapshots() {
        skillSnapshots = skills.map(SkillSnapshotConfig.init(skill:))
    }

    private var effectiveSkillSnapshots: [SkillSnapshotConfig] {
        let liveSnapshots = skills.map(SkillSnapshotConfig.init(skill:))
        guard !skillSnapshots.isEmpty else { return liveSnapshots }
        guard !liveSnapshots.isEmpty else { return skillSnapshots }

        var combined = liveSnapshots
        var seenIDs = Set(liveSnapshots.compactMap(\.id))
        var seenNames = Set(liveSnapshots.map { $0.name.lowercased() })

        for snapshot in skillSnapshots {
            let hasMatchingID = snapshot.id.map { seenIDs.contains($0) } ?? false
            let nameKey = snapshot.name.lowercased()
            guard !hasMatchingID && !seenNames.contains(nameKey) else { continue }
            combined.append(snapshot)
            if let id = snapshot.id {
                seenIDs.insert(id)
            }
            seenNames.insert(nameKey)
        }

        return combined
    }

    private var detachedSkillSnapshots: [SkillSnapshotConfig] {
        guard !skillSnapshots.isEmpty else { return [] }
        guard !skills.isEmpty else { return skillSnapshots }

        let liveIDs = Set(skills.map { $0.id.uuidString })
        let liveNames = Set(skills.map { $0.name.lowercased() })

        return skillSnapshots.filter { snapshot in
            if let id = snapshot.id, liveIDs.contains(id) {
                return false
            }
            return !liveNames.contains(snapshot.name.lowercased())
        }
    }

    var isForked: Bool { forkedFromID != nil }

    static func fork(from source: AgentTask, upToRun targetRun: TaskRun, in context: ModelContext) -> AgentTask {
        let forked = AgentTask(
            title: "Fork of \(source.title)",
            goal: source.goal,
            workspace: source.workspace,
            tokenBudget: source.tokenBudget,
            model: source.model,
            isolationStrategy: source.isolationStrategy,
            validationStrategy: source.validationStrategy
        )
        forked.inputs = source.inputs
        forked.constraints = source.constraints
        forked.acceptanceCriteria = source.acceptanceCriteria
        forked.forkedFromID = source.id
        forked.skills = source.skills
        forked.skillSnapshotsJSON = source.skillSnapshotsJSON

        let sortedRuns = source.runs.sorted { $0.startedAt < $1.startedAt }
        guard let cutoffIndex = sortedRuns.firstIndex(where: { $0.id == targetRun.id }) else {
            context.insert(forked)
            return forked
        }

        forked.forkedAtRunIndex = cutoffIndex
        forked.status = .completed

        let runsToFork = sortedRuns.prefix(through: cutoffIndex)
        var totalTokens = 0
        var totalCost = 0.0

        for sourceRun in runsToFork {
            let newRun = TaskRun(task: forked)
            newRun.status = sourceRun.status
            newRun.startedAt = sourceRun.startedAt
            newRun.completedAt = sourceRun.completedAt
            newRun.tokensUsed = sourceRun.tokensUsed
            newRun.inputTokens = sourceRun.inputTokens
            newRun.outputTokens = sourceRun.outputTokens
            newRun.output = sourceRun.output
            newRun.costUSD = sourceRun.costUSD
            newRun.fileChangesJSON = sourceRun.fileChangesJSON
            newRun.stopReason = sourceRun.stopReason
            newRun.exitCode = sourceRun.exitCode
            context.insert(newRun)
            totalTokens += sourceRun.tokensUsed
            totalCost += sourceRun.costUSD
        }

        forked.tokensUsed = totalTokens
        forked.costUSD = totalCost

        let cutoffDate = targetRun.completedAt ?? targetRun.startedAt
        let eventsToFork = source.events
            .filter { $0.timestamp <= cutoffDate }
            .sorted { $0.timestamp < $1.timestamp }

        for sourceEvent in eventsToFork {
            let newEvent = TaskEvent(
                task: forked,
                type: sourceEvent.type,
                payload: sourceEvent.payload
            )
            newEvent.timestamp = sourceEvent.timestamp
            newEvent.agentName = sourceEvent.agentName
            newEvent.agentId = sourceEvent.agentId
            newEvent.teamName = sourceEvent.teamName
            context.insert(newEvent)
        }

        context.insert(forked)
        return forked
    }

    var isTerminal: Bool {
        [.completed, .failed, .cancelled, .budgetExceeded].contains(status)
    }

    var budgetProgress: Double {
        guard tokenBudget > 0 else { return 0 }
        return min(1.0, max(0, Double(tokensUsed) / Double(tokenBudget)))
    }

    var threadMessageCount: Int {
        let messageCount = events.filter { event in
            event.type == "user.message" || event.type == "agent.response"
        }.count

        if messageCount > 0 {
            return messageCount
        }

        return goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
    }

    var statusColor: String {
        switch status {
        case .draft: return "purple"
        case .queued: return "gray"
        case .running: return "blue"
        case .pendingUser: return "orange"
        case .completed: return "green"
        case .failed: return "red"
        case .cancelled: return "gray"
        case .budgetExceeded: return "red"
        }
    }

    func makeSkillResolver() -> SkillResolver {
        let standaloneTools = allLocalTools.filter { $0.skill == nil }
        let standaloneSnapshots = standaloneTools.map(LocalToolSnapshotConfig.init(localTool:))

        let liveCLICommands = Set(
            allLocalTools
                .filter { $0.toolType != "mcp" && !$0.command.isEmpty }
                .map(\.command)
        )

        var liveEnvVars: [String: String] = [:]
        for skill in skills {
            for (key, value) in skill.resolvedAllEnvironmentVariables {
                liveEnvVars[key] = value
            }
        }

        var connEnvVars: [String: String] = [:]
        for connector in allConnectors {
            for (key, value) in connector.allEnvironmentVariables {
                connEnvVars[key] = value
            }
        }

        return SkillResolver(
            effectiveSnapshots: effectiveSkillSnapshots,
            detachedSnapshots: detachedSkillSnapshots,
            standaloneToolSnapshots: standaloneSnapshots,
            liveLocalToolCommands: liveCLICommands,
            liveSkillEnvVars: liveEnvVars,
            connectorEnvVars: connEnvVars
        )
    }

    var resolvedAllowedTools: [String] { makeSkillResolver().resolvedAllowedTools }
    var resolvedDisallowedTools: [String] { makeSkillResolver().resolvedDisallowedTools }
    var resolvedClaudeAllowedTools: [String] { makeSkillResolver().resolvedClaudeAllowedTools }
    var resolvedBehaviorInstructions: String { makeSkillResolver().resolvedBehaviorInstructions }
    var resolvedEnvironmentVariables: [String: String] { makeSkillResolver().resolvedEnvironmentVariables }

    var toolPermissionConflicts: [ToolPermissionConflict] {
        makeSkillResolver().toolPermissionConflicts.map {
            ToolPermissionConflict(tool: $0.tool, allowedBy: $0.allowedBy, disallowedBy: $0.disallowedBy)
        }
    }

    /// All connectors: from attached skills + standalone workspace connectors + enabled global connectors
    var allConnectors: [Connector] {
        let fromSkills = skills.flatMap(\.connectors)
        let standalone = workspace?.connectors.filter { $0.skill == nil } ?? []
        var all = fromSkills + standalone

        if let ws = workspace, !ws.enabledGlobalConnectorIDs.isEmpty, let ctx = modelContext {
            let enabledIDs = Set(ws.enabledGlobalConnectorIDs)
            let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
            if let globals = try? ctx.fetch(descriptor) {
                all += globals.filter { enabledIDs.contains($0.id.uuidString) }
            }
        }

        var seen = Set<UUID>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// All local tools: from attached skills + standalone workspace tools + enabled global tools
    var allLocalTools: [LocalTool] {
        let fromSkills = skills.flatMap(\.localTools)
        let standalone = workspace?.localTools.filter { $0.skill == nil } ?? []
        var all = fromSkills + standalone

        if let ws = workspace, !ws.enabledGlobalToolIDs.isEmpty, let ctx = modelContext {
            let enabledIDs = Set(ws.enabledGlobalToolIDs)
            let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true })
            if let globals = try? ctx.fetch(descriptor) {
                all += globals.filter { enabledIDs.contains($0.id.uuidString) }
            }
        }

        var seen = Set<UUID>()
        return all.filter { seen.insert($0.id).inserted }
    }
}
