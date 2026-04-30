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
    var runtimeID: String?
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
    var unreadAt: Date?
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

    var workspaceAccess: TaskWorkspaceAccess {
        TaskWorkspaceAccess(task: self)
    }

    var effectiveWorkspacePath: String {
        workspaceAccess.effectiveWorkspacePath
    }

    /// The directory where the Claude CLI process should actually run.
    /// Prefers the first additional path (where the actual code lives) over the
    /// Astra workspace folder (which is for metadata/task outputs).
    var codeWorkingDirectory: String {
        workspaceAccess.codeWorkingDirectory
    }

    /// Per-task subfolder within the workspace for task-specific outputs
    var taskFolder: String {
        workspaceAccess.taskFolder
    }

    var canonicalTaskFolder: String {
        workspaceAccess.canonicalTaskFolder
    }

    /// Ensures the task folder exists on disk, creating it if needed.
    /// Throws if the directory cannot be created.
    @discardableResult
    func ensureTaskFolder(fileSystem: FileSystem = RealFileSystem()) throws -> String {
        try workspaceAccess.ensureTaskFolder(fileSystem: fileSystem)
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
        self.runtimeID = AgentRuntimeID.claudeCode.rawValue
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
        self.unreadAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var resolvedRuntimeID: AgentRuntimeID {
        AgentRuntimeID(rawValue: runtimeID ?? "") ?? .claudeCode
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

    var isForked: Bool { forkedFromID != nil }

    static func fork(from source: AgentTask, upToRun targetRun: TaskRun, in context: ModelContext) -> AgentTask {
        AgentTaskForkService.fork(from: source, upToRun: targetRun, in: context)
    }

    var isTerminal: Bool {
        [.completed, .failed, .cancelled, .budgetExceeded].contains(status)
    }

    var shouldShowUnread: Bool {
        unreadAt != nil
    }

    func markUnreadForCurrentStatus(at date: Date = Date()) {
        if [.completed, .failed, .pendingUser, .budgetExceeded].contains(status) {
            unreadAt = date
        } else {
            unreadAt = nil
        }
    }

    func markRead() {
        unreadAt = nil
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
        TaskPresentationState.statusColor(for: status)
    }

    func makeSkillResolver() -> SkillResolver {
        TaskCapabilityResolver(task: self).resolver
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
        TaskCapabilityResolver(task: self).allConnectors
    }

    /// All local tools: from attached skills + standalone workspace tools + enabled global tools
    var allLocalTools: [LocalTool] {
        TaskCapabilityResolver(task: self).allLocalTools
    }
}
