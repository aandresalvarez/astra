import Foundation
import SwiftData
import ASTRACore

enum TaskStatus: String, Codable, CaseIterable, Sendable {
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
    /// The code root this thread is pinned to for its entire life, captured at
    /// creation time. `nil` means resolve from the workspace as before. A
    /// non-nil value is the absolute path of a git worktree, so resuming this
    /// thread always lands in the same checkout regardless of how the
    /// workspace's active location later changes.
    var executionRootPath: String?
    /// JSON-encoded immutable execution environment for this thread. Nil means
    /// host unless the first run snapshots the workspace default.
    var executionEnvironmentSnapshotJSON: String?
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

    init(
        title: String,
        goal: String,
        workspace: Workspace? = nil,
        tokenBudget: Int = TaskExecutionDefaults.tokenBudget,
        model: String = TaskExecutionDefaults.model,
        runtime: AgentRuntimeID = TaskExecutionDefaults.runtime,
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
        self.runtimeID = runtime.rawValue
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
        // Pin the thread to the workspace's active code location at creation so
        // it always runs in the same checkout/repository, even if the workspace
        // later switches its default.
        self.executionRootPath = workspace?.isUsingWorktree == true ? workspace?.activeWorkingPath : nil
        self.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(
            ExecutionEnvironmentStore.decode(workspace?.activeExecutionEnvironmentJSON)
        )
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var resolvedRuntimeID: AgentRuntimeID {
        AgentRuntimeID(rawValue: runtimeID ?? "") ?? TaskExecutionDefaults.runtime
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

    var isForked: Bool { forkedFromID != nil }

    var hasProviderSession: Bool {
        sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

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

        return Self.fallbackThreadMessageCount(forGoal: goal)
    }

    static func fallbackThreadMessageCount(forGoal goal: String) -> Int {
        goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
    }

    var statusColor: String {
        TaskPresentationState.statusColor(for: status)
    }

}
