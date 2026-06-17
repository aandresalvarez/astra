import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

/// Covers `TaskLifecycleCoordinator.resumeTask`, the UI "continue where you left
/// off" path. The continuation is driven through a zero-size `TaskQueue` pool so
/// no real provider process is launched: `TaskQueue.continueSession` finds no
/// available worker and returns immediately, leaving only the deterministic,
/// synchronous resume bookkeeping to assert.
@Suite("Task resume continuation (HITL)")
@MainActor
struct TaskLifecycleResumeTests {

    private struct Environment {
        let coordinator: TaskLifecycleCoordinator
        let context: ModelContext
        let container: ModelContainer
        let root: String
    }

    private func makeEnvironment() throws -> Environment {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let queue = TaskQueue(poolSize: 0)
        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: queue)
        return Environment(coordinator: coordinator, context: context, container: container, root: url.path)
    }

    @Test("Resume without a session id does not start a continuation")
    func resumeWithoutSessionIDDoesNotStart() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume Guard", primaryPath: env.root)
        let task = AgentTask(title: "Guard", goal: "Finish later", workspace: workspace)
        task.status = .completed
        task.sessionId = nil
        env.context.insert(workspace)
        env.context.insert(task)

        env.coordinator.resumeTask(task)

        #expect(task.status == .completed)
        #expect(task.events.contains { $0.type == "task.resumed" } == false)
    }

    @Test("Resume with a session id marks running and records a resume event")
    func resumeWithSessionIDMarksRunningAndRecordsEvent() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume", primaryPath: env.root)
        let task = AgentTask(title: "Resume", goal: "Complete the original goal", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-resume-123"
        env.context.insert(workspace)
        env.context.insert(task)

        let continuation = env.coordinator.resumeTask(task)

        // resumeTask performs these mutations synchronously, before the
        // continuation Task is scheduled, so they are deterministic to assert.
        #expect(task.status == .running)
        let resumeEvents = task.events.filter { $0.type == "task.resumed" }
        #expect(resumeEvents.count == 1)
        #expect(resumeEvents.first?.payload.contains("Resuming previous session") == true)

        // Drain the continuation; with a zero-size pool `continueSession` cannot
        // admit a worker and returns false, so the optimistic `.running` must be
        // rolled back to the prior status rather than stranding the task.
        await continuation?.value
        _ = env.container
    }

    @Test("Resume reverts to the prior status when no worker can continue")
    func resumeRevertsWhenNoWorkerCanContinue() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume Revert", primaryPath: env.root)
        let task = AgentTask(title: "Resume Revert", goal: "Complete the original goal", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-resume-revert"
        env.context.insert(workspace)
        env.context.insert(task)

        // Zero-size pool → `continueSession` finds no worker and returns false.
        await env.coordinator.resumeTask(task)?.value

        #expect(task.status == .pendingUser)
        #expect(task.runs.filter { $0.status == .running }.isEmpty)
        #expect(task.events.contains { $0.type == "error" })
    }

    @Test("Runtime permission approval reverts to pendingUser when no worker can continue")
    func runtimePermissionApprovalRevertsWhenNoWorkerCanContinue() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Approval Revert", primaryPath: env.root)
        let task = AgentTask(title: "Approval Revert", goal: "Do the thing", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-approval-revert"
        env.context.insert(workspace)
        env.context.insert(task)

        let approvalRun = TaskRun(task: task)
        approvalRun.status = .failed
        approvalRun.stopReason = "permission_approval_required"
        approvalRun.completedAt = Date()
        env.context.insert(approvalRun)
        // Legacy pause-and-relaunch ask (no requestID) → still an open request,
        // so approveTask routes through approveRuntimePermissionAndContinue.
        env.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: "Permission requested for tool: shell(gh:repo view *).",
            run: approvalRun
        ))
        try env.context.save()

        // No live in-flight ask is registered, so approval takes the relaunch
        // path; the zero-size pool then refuses admission and must roll back.
        await env.coordinator.approveTask(task)?.value

        #expect(task.status == .pendingUser)
        #expect(task.runs.filter { $0.status == .running }.isEmpty)
        #expect(task.events.contains { $0.type == "error" })
    }

    @Test("Resume preserves a queue-recorded .failed instead of reverting over it")
    func resumePreservesQueueRecordedFailure() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        // A regular file where the workspace root should be: ensureTaskFolder's
        // createDirectory then throws, so TaskQueue.prepareTaskFolder sets
        // `.failed`, records its own error, and returns false *after* mutating.
        let blocker = (env.root as NSString).appendingPathComponent("blocker")
        FileManager.default.createFile(atPath: blocker, contents: Data("x".utf8))
        let wsPath = (blocker as NSString).appendingPathComponent("ws")

        // A real worker (poolSize 1) so continueSession gets past the
        // worker/lock guards and actually reaches prepareTaskFolder.
        let queue = TaskQueue(poolSize: 1)
        let coordinator = TaskLifecycleCoordinator(modelContext: env.context, taskQueue: queue)

        let workspace = Workspace(name: "Folder Fail", primaryPath: wsPath)
        let task = AgentTask(title: "Folder Fail", goal: "Complete the original goal", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-folder-fail"
        env.context.insert(workspace)
        env.context.insert(task)

        await coordinator.resumeTask(task)?.value

        // The queue's `.failed` must survive — not be overwritten back to
        // pendingUser — and only one error event should exist (the queue's).
        #expect(task.status == .failed)
        #expect(task.events.filter { $0.type == "error" }.count == 1)
    }

    @Test("Resume continuation uses the canonical continue message")
    func resumeContinuationMessageIsStable() {
        #expect(
            TaskLifecycleCoordinator.resumeContinuationMessage
                == "Continue where you left off. Complete the original goal."
        )
    }

    @Test("Retry replays the latest actionable follow-up instead of the original task seed")
    func retryReplaysLatestActionableFollowUpInsteadOfOriginalTaskSeed() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("opencode-retry-args.txt")
        let opencodePath = try harness.writeExecutable(
            named: "opencode",
            script: Self.fakeOpenCodeScript(argsFile: argsFile)
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(opencodePath, for: .openCodeCLI)
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            providerSettings: settings,
            defaultRuntimeID: .openCodeCLI,
            timeoutSeconds: 5,
            validationModel: "opencode/big-pickle"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        let task = harness.makeTask(
            runtime: .openCodeCLI,
            goal: "hi , how are you ?",
            model: "opencode/big-pickle"
        )
        task.status = .pendingUser

        let followUpRun = TaskRun(task: task)
        followUpRun.status = .failed
        followUpRun.stopReason = "permission_approval_required"
        followUpRun.completedAt = Date()
        harness.context.insert(followUpRun)
        harness.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "check my open prs in github",
            run: followUpRun
        ))
        let approvalRun = TaskRun(task: task)
        approvalRun.status = .failed
        approvalRun.stopReason = "no_usable_result"
        approvalRun.completedAt = Date().addingTimeInterval(1)
        harness.context.insert(approvalRun)
        harness.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "ASTRA approved task-scoped runtime permission for similar requests in this task: shell(gh:repo view *). Continue the original task from where it stopped.",
            run: approvalRun
        ))
        try harness.context.save()

        // Await the retry continuation to fully drain. The continuation is a
        // detached Task that keeps touching `task` (the trailing audit) after the
        // worker finishes; without awaiting it, the harness — and its in-memory
        // ModelContainer — can be torn down mid-continuation, destroying the model
        // it still references and crashing the whole test process under suite
        // parallelism. Awaiting the handle also guarantees the fake provider has
        // written `argsFile` before we read it.
        await coordinator.retryTask(task)?.value

        #expect(task.status == .completed)
        let rawArgs = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(rawArgs.contains("User's follow-up request:\ncheck my open prs in github"))
        #expect(!rawArgs.contains("User's follow-up request:\nhi , how are you ?"))
    }

    @Test("Retry follow-up remains queued when no worker can continue")
    func retryFollowUpRemainsQueuedWhenNoWorkerCanContinue() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Retry Guard", primaryPath: env.root)
        let task = AgentTask(title: "Retry Guard", goal: "Initial request", workspace: workspace)
        task.status = .pendingUser
        env.context.insert(workspace)
        env.context.insert(task)

        let failedRun = TaskRun(task: task)
        failedRun.status = .failed
        failedRun.stopReason = "permission_approval_required"
        failedRun.completedAt = Date()
        env.context.insert(failedRun)
        env.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "latest follow-up request",
            run: failedRun
        ))
        try env.context.save()

        // Drain the continuation deterministically (with a zero-size pool it
        // returns immediately without launching a provider).
        await env.coordinator.retryTask(task)?.value
        AppLogger.flushForTesting()

        #expect(task.status == .queued)
        #expect(task.runs.filter { $0.status == .running }.isEmpty)
        #expect(task.events.contains { $0.type == "task.retried" })
        #expect(
            AppLogger.entries.contains {
                $0.taskID == task.id && $0.message.contains("task.completed")
            } == false
        )
    }

    private static func fakeOpenCodeScript(argsFile: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "opencode fake 1.0"
          exit 0
        fi
        printf '%s\\n' "$@" > \(HeadlessChatScenarioTests.shQuote(argsFile.path))
        printf '%s\\n' '{"type":"text","sessionID":"retry-session","part":{"type":"text","text":"Retried latest follow-up."}}'
        printf '%s\\n' '{"type":"step_finish","sessionID":"retry-session","part":{"type":"step-finish","reason":"stop","tokens":{"total":4,"input":3,"output":1,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0}}'
        exit 0
        """
    }
}
