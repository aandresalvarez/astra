import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

extension HeadlessChatScenarioTests {
    @Test("A new user request after a budget stop gets fresh limits while Retry does not launch again", arguments: [false, true])
    func requestBudgetAfterBudgetStop(retryFirst: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        h.context.autosaveEnabled = false
        defer { h.cleanup() }
        let launches = h.rootURL.appendingPathComponent("request-launches")
        let cli = try h.writeExecutable(named: "claude", script: Self.claudeScript(body: """
        printf 'launch\\n' >> \(Self.shQuoteSandboxPath(launches.path))
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"request-budget-stop","model":"test"}'
        printf '%s\\n' '{"type":"result","is_error":false,"duration_ms":10,"num_turns":1,"result":"Complete","usage":{"input_tokens":209990,"output_tokens":10}}'
        exit 0
        """))
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic request", model: "test", tokenBudget: 200_000)
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: cli)
        worker.budgetEnforcementModeOverride = .hardStop
        _ = await h.execute(task: task, worker: worker)
        #expect(task.status == .budgetExceeded)
        let stopped = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        try #require(stopped.canReplace)
        #expect(stopped.limits.tokenCeiling == 200_000 && stopped.limits.tokensSpent == 210_000)

        task.tokenBudget = 300_000
        if retryFirst {
            let retry = try ExecutionRequestSubmissionService.submitRetry(message: "Continue the interrupted request",
                continuation: true, for: task, into: h.context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: retry.requestID, in: h.context))
            #expect(RuntimeExecutionAdmission.resolve(request: request, task: task) == .recovery)
            _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
            DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: h.context)
            await worker.continueSession(task: task, message: "Continue the interrupted request",
                existingMessageEventID: retry.eventID, turnRequestID: retry.requestID, modelContext: h.context) { _ in }
            #expect(try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count == 1)
            let retried = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
            var remaining = stopped.limits
            remaining.secondsRemaining = retried.limits.secondsRemaining
            #expect(remaining.secondsRemaining < stopped.limits.secondsRemaining && remaining.secondsRemaining > 0)
            #expect(retried.limits == remaining)
            #expect(task.tokensUsed == 210_000)
        }

        _ = await h.continueTask(task: task, message: "A separate new request", worker: worker)
        #expect(task.status == .completed)
        #expect(try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count == 2)
        #expect(task.tokensUsed == 420_000)
        let fresh = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(fresh.limits.tokenCeiling == 300_000 && fresh.limits.tokensSpent == 210_000)
        let latest = try #require(task.runs.max(by: TaskRun.isChronologicallyOrdered))
        #expect(latest.status == .completed && latest.tokensUsed == 210_000)
        let budget = TaskRequestBudget(run: latest, task: task)
        #expect(budget.tokenCeiling == 300_000 && budget.tokensUsed == 210_000)
    }

    @Test("A new user request cannot replace uncertain work or reset its remaining limits")
    func requestBudgetStillRequiresStoppedProof() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        h.context.autosaveEnabled = false
        defer { h.cleanup() }
        let launches = h.rootURL.appendingPathComponent("uncertain-request-launch")
        let cli = try h.writeExecutable(named: "claude", script: Self.claudeScript(body: """
        printf 'launch\\n' > \(Self.shQuoteSandboxPath(launches.path))
        exit 0
        """))
        let task = h.makeTask(runtime: .claudeCode, goal: "Uncertain request", model: "test", tokenBudget: 200_000)
        task.status = .budgetExceeded; task.tokensUsed = 210_000
        let run = TaskRun(task: task); run.status = .budgetExceeded
        run.tokensUsed = 210_000; h.context.insert(run)
        let prior = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        task.tokenBudget = 300_000
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: cli)
        _ = await h.continueTask(task: task, message: "A separate new request", worker: worker)
        #expect(!FileManager.default.fileExists(atPath: launches.path))
        #expect(task.runs.count == 1 && task.tokensUsed == 210_000)
        let retained = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(retained.ownerID == prior.ownerID && retained.limits == prior.limits)
        #expect(retained.stopProof == prior.stopProof)
    }

    @Test("Recovery, plan and permission continuations keep limits after stopped or finished requests")
    func requestBudgetContinuationDoesNotRefill() throws {
        for (state, source) in [RuntimeExecutionOwnerRecord.State.stopped, .finished].flatMap({ state in
            ["retry", "resume", "plan", "permission"].map { (state, $0) }
        }) {
            let h = try HeadlessChatHarness(persistentStore: true)
            h.context.autosaveEnabled = false
            defer { h.cleanup() }
            let task = h.makeTask(runtime: .claudeCode, goal: "Continue", model: "test", tokenBudget: 200_000)
            task.status = state == .finished ? .completed : .budgetExceeded
            task.tokensUsed = 210_000
            let run = TaskRun(task: task)
            run.status = state == .finished ? .completed : .budgetExceeded
            h.context.insert(run)
            var prior = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context)
            prior.state = state
            do {
                let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
                try lease.save(prior)
            }
            task.tokenBudget = 300_000
            let submission: ExecutionRequestSubmissionService.Submission
            switch source {
            case "retry":
                submission = try ExecutionRequestSubmissionService.submitRetry(message: "Retry", continuation: true,
                    for: task, into: h.context).get()
            case "resume":
                submission = try ExecutionRequestSubmissionService.submitResume(message: "Resume",
                    for: task, into: h.context).get()
            case "plan":
                let plan = TaskPlanPayload(title: "Approved", goal: "Continue", steps: [.init(id: "one", title: "Next")])
                submission = try ExecutionRequestSubmissionService.submitPlan(plan: plan, mode: .nextStep,
                    mutation: .existingTask, for: task, into: h.context).get()
            default:
                let continuation = TaskPermissionContinuation.capture(task: task, run: run, modelContext: h.context, mode: .live)
                submission = try ExecutionRequestSubmissionService.submitPermissionResume(message: "Approved",
                    executionPolicy: .default, for: task, into: h.context, continuation: continuation, approvalID: "approval").get()
            }
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
            let admission = RuntimeExecutionAdmission.resolve(request: request, task: task)
            #expect(admission == (source == "plan" || source == "permission" ? .approvedContinuation : .recovery))
            let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
                maxRunSeconds: 999, newUserTurn: admission.isNewUserTurn, newUserRequest: admission == .userInstruction))
            #expect(owner.isRecovery && owner.record.limits == prior.limits)
            owner.finish()
        }
    }

    @Test("Replaying the same user request after reopening keeps its original allowance")
    func requestBudgetReplayDoesNotRefill() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        h.context.autosaveEnabled = false
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Replay", model: "test", tokenBudget: 200_000)
        let submitted = try ExecutionRequestSubmissionService.submitFollowUp(message: "One request",
            for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
        #expect(RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction)
        let run = TaskRun(task: task); h.context.insert(run)
        PersistedTurnRuntimeEventLinker.link(eventID: submitted.eventID, to: run, for: task,
            fallbackType: TaskEventTypes.Conversation.userMessage.rawValue, fallbackPayload: "One request", in: h.context)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: run.id)
        _ = TaskTurnRequestStateMachine.transition(request, to: .failed, terminalReason: "max_budget_reached")
        _ = TaskTurnRequestStateMachine.transition(request, to: .waitingForWorker)
        #expect(request.runID == nil && request.startedAt == nil)
        task.status = .budgetExceeded; task.tokensUsed = 210_000; run.status = .budgetExceeded
        let prior = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context)
        task.tokenBudget = 300_000
        try h.context.save()

        let reopened = ModelContext(h.container); reopened.autosaveEnabled = false
        let restored = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        let restoredRequest = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: reopened))
        let admission = RuntimeExecutionAdmission.resolve(request: restoredRequest, task: restored)
        #expect(admission == .recovery)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: restored, context: reopened, maxRunSeconds: 999,
            newUserTurn: admission.isNewUserTurn, newUserRequest: admission == .userInstruction))
        defer { owner.finish() }
        #expect(owner.isRecovery && owner.record.limits == prior.limits)
    }

    @Test("Each new request has its own ceiling while history continues accumulating")
    func requestBudgetExcludesPreviousRequests() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let marker = Self.shQuoteSandboxPath(h.rootURL.appendingPathComponent("request-budget-first").path)
        let cli = try h.writeExecutable(named: "claude", script: Self.claudeScript(body: """
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"request-budget","model":"test"}'
        if [ -e \(marker) ]; then
          input=239980; output=20
        else
          touch \(marker)
          input=119990; output=10
        fi
        printf '{"type":"result","is_error":false,"session_id":"request-budget","duration_ms":10,"num_turns":1,"result":"Complete","usage":{"input_tokens":119990,"output_tokens":10},"modelUsage":{"m":{"inputTokens":%s,"outputTokens":%s}},"total_cost_usd":0}\\n' "$input" "$output"
        exit 0
        """))
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic request", model: "test", tokenBudget: 200_000)
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: cli)
        worker.budgetEnforcementModeOverride = .hardStop
        _ = await h.execute(task: task, worker: worker)
        #expect(task.status == .completed)
        _ = await h.continueTask(task: task, message: "Another independent request", worker: worker)
        #expect(task.status == .completed)
        #expect(task.tokensUsed == 240_000)
        #expect(task.budgetProgress == 0.6)
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
        let run = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(run.tokensUsed == 120_000)
        let receipt = try #require(try RuntimeExecutionOwner.store(in: h.context).read(taskID: task.id, taskOwnerID: task.persistentModelID))
        #expect(receipt.limits.tokenCeiling == 200_000)
        #expect(receipt.limits.tokensSpent == 120_000)
    }
}
