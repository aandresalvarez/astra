import Foundation
import SwiftData
import ASTRACore

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case queued
    case running
    case pendingUser = "pending_user"
    case completed
    case failed
    case cancelled
    case budgetExceeded = "budget_exceeded"
}

public enum IsolationStrategy: String, Codable, CaseIterable {
    case sameDirectory = "same_directory"
    case gitBranch = "git_branch"
    case copy
}

public enum ValidationStrategy: String, Codable, CaseIterable {
    case manual
    case runTests = "run_tests"
    case aiCheck = "ai_check"
}

@Model
public final class AgentTask {
    public var id: UUID
    public var title: String
    public var goal: String
    public var inputs: [String]
    public var constraints: [String]
    public var acceptanceCriteria: [String]
    public var status: TaskStatus
    public var workspace: Workspace?
    public var isolationStrategy: IsolationStrategy
    public var validationStrategy: ValidationStrategy
    public var tokenBudget: Int
    public var tokensUsed: Int
    public var model: String
    public var runtimeID: String?
    /// True when the current `runtimeID` was set by the user explicitly
    /// picking a runtime in the composer (`task_runtime_changed`), as opposed
    /// to being assigned by task creation or an automatic compatibility
    /// reroute. `AgentRuntimeLaunchRuntimeResolver` uses this to decide
    /// whether an incompatible runtime should be rerouted silently or
    /// reported as an up-front, actionable block that respects the user's
    /// choice instead of overriding it.
    public var runtimeExplicitlySelected: Bool = false
    public var testCommand: String
    public var costUSD: Double
    public var queuePosition: Int
    public var sessionId: String?
    public var chainedGoal: String          // If set, auto-creates a follow-up task on completion
    public var chainedFromID: UUID?         // ID of the task that spawned this one
    public var forkedFromID: UUID?          // ID of the source task this was forked from
    public var forkedAtRunIndex: Int        // Index of the run at the fork point (0-based)
    public var draftMessages: String        // JSON-encoded conversation for draft tasks
    public var maxTurns: Int               // 0 = unlimited
    // Agent Teams
    public var useAgentTeam: Bool
    public var teamSize: Int
    public var teamInstructions: String
    public var templateID: UUID?          // TaskTemplate this task was created from
    public var templateHooksJSON: String   // Hooks to inject during execution (from template)
    public var originScheduleID: UUID?    // Schedule that spawned this task (for result routing)
    public var skillSnapshotsJSON: String  // JSON-encoded task-time skill definitions for durable history
    public var isPinned: Bool
    public var isDone: Bool
    public var unreadAt: Date?
    /// The code root this thread is pinned to for its entire life, captured at
    /// creation time. `nil` means resolve from the workspace as before. A
    /// non-nil value is the absolute path of a git worktree, so resuming this
    /// thread always lands in the same checkout regardless of how the
    /// workspace's active location later changes.
    public var executionRootPath: String?
    /// JSON-encoded immutable execution environment for this thread. Nil means
    /// host unless the first run snapshots the workspace default.
    public var executionEnvironmentSnapshotJSON: String?
    /// JSON-encoded runtime permission requests that are currently open for
    /// user action. Events remain the audit trail; this field owns live state.
    public var runtimePermissionOpenRequestsJSON: String?
    /// JSON-encoded task-scoped runtime permission grants approved for reuse.
    /// Events remain the audit trail; this field owns replay decisions.
    public var runtimePermissionGrantsJSON: String?
    /// Stable raw value for the last shelf the user explicitly chose for this
    /// task. This is task-owned durable state; transient panel visibility stays
    /// in the presentation model. Nil means no shelf should be restored.
    public var rememberedWorkspaceCanvasItemRawValue: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \TaskRun.task)
    public var runs: [TaskRun] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskEvent.task)
    public var events: [TaskEvent] = []

    @Relationship(deleteRule: .cascade, inverse: \Artifact.task)
    public var artifacts: [Artifact] = []

    @Relationship
    public var skills: [Skill] = []

    public init(
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
        self.runtimePermissionOpenRequestsJSON = "[]"
        self.runtimePermissionGrantsJSON = "[]"
        self.rememberedWorkspaceCanvasItemRawValue = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var resolvedRuntimeID: AgentRuntimeID {
        AgentRuntimeID(rawValue: runtimeID ?? "") ?? TaskExecutionDefaults.runtime
    }

    public var skillSnapshots: [SkillSnapshotConfig] {
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

    public var isForked: Bool { forkedFromID != nil }

    public var hasProviderSession: Bool {
        sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @MainActor
    public static func fork(
        from source: AgentTask,
        upToRun targetRun: TaskRun,
        options: TaskForkOptions = TaskForkOptions(),
        in context: ModelContext
    ) throws -> AgentTask {
        try AgentTaskForkService.fork(from: source, upToRun: targetRun, options: options, in: context)
    }

    public var isTerminal: Bool {
        [.completed, .failed, .cancelled, .budgetExceeded].contains(status)
    }

    public var shouldShowUnread: Bool {
        unreadAt != nil
    }

    public func markUnreadForCurrentStatus(at date: Date = Date()) {
        if [.completed, .failed, .pendingUser, .budgetExceeded].contains(status) {
            unreadAt = date
        } else {
            unreadAt = nil
        }
    }

    public func markRead() {
        unreadAt = nil
    }

    public var budgetProgress: Double {
        guard tokenBudget > 0 else { return 0 }
        return min(1.0, max(0, Double(tokensUsed) / Double(tokenBudget)))
    }

    public var threadMessageCount: Int {
        let messageCount = events.filter { event in
            event.type == "user.message" || event.type == "agent.response"
        }.count

        if messageCount > 0 {
            return messageCount
        }

        return Self.fallbackThreadMessageCount(forGoal: goal)
    }

    public static func fallbackThreadMessageCount(forGoal goal: String) -> Int {
        goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
    }

    public var statusColor: String {
        TaskStatusPresentation.color(for: status.rawValue)
    }

}
