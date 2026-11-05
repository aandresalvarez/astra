import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace consultation runtime boundaries", .serialized)
@MainActor
struct WorkspaceConsultationRuntimeTests {
    @Test("An unverifiable supplied request never becomes a direct launch",
          arguments: ["initial", "resume", "full_plan", "final_only"],
          ["missing", "unreadable", "wrong_owner", "wrong_context", "wrong_id"])
    func unverifiableRequestStopsBeforeExecution(route: String, fault: String) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6", tokenBudget: 0)
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let marker = harness.workspaceURL.appendingPathComponent("missing-request-command-ran")
        try ".PHONY: test\ntest:\n\t@printf 'ran\\n' >> missing-request-command-ran\n"
            .write(to: harness.workspaceURL.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let plan = TaskPlanPayload(title: "Synthetic plan", goal: task.goal,
            steps: [.init(id: "explain", title: "Explain", status: route == "final_only" ? .done : .pending)],
            validationContract: .init(assertions: [.init(id: "command", description: "Synthetic command",
                method: .command, command: "make test")]))
        let request = try submit(task, context: harness.context)
        var requestID = request.id
        let policy = admissionPolicy(request, task: task)
        var reader: RuntimeExecutionAdmission.RequestReader = { try TaskTurnRequestRepository.request(id: $0, in: $1) }
        var retainedContext: ModelContext?
        var foreignRequest: TaskTurnRequest?
        defer { withExtendedLifetime(retainedContext) {} }
        switch fault {
        case "missing": harness.context.delete(request)
        case "unreadable": reader = { _, _ in throw FixtureError.read }
        case "wrong_owner":
            let other = harness.makeTask(runtime: .claudeCode, goal: "Different task", model: "claude-sonnet-4-6")
            foreignRequest = try submit(other, context: harness.context)
            requestID = try #require(foreignRequest?.id)
        case "wrong_context":
            try harness.context.save()
            let otherContext = ModelContext(harness.container)
            retainedContext = otherContext
            let otherRow = try #require(try TaskTurnRequestRepository.request(id: request.id, in: otherContext))
            foreignRequest = otherRow
            reader = { _, _ in otherRow }
        default:
            requestID = UUID()
            reader = { _, _ in request }
        }
        TaskWorkspaceConsultationPolicy.apply(false, to: task)
        try harness.context.save()
        let fake = FakeAgentProcessRunner()
        fake.streamLines = [#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Synthetic answer."}]}}"#]
        let worker = makeWorker(fake, runtime: .claudeCode, root: harness.rootURL, requestReader: reader)
        switch route {
        case "initial":
            DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: harness.context)
            await worker.execute(task: task, modelContext: harness.context, executionRequestID: requestID,
                executionPolicy: policy) { _ in }
        case "resume":
            task.status = .completed
            DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: harness.context)
            await worker.continueSession(task: task, message: "Explain again", turnRequestID: requestID,
                modelContext: harness.context, executionPolicy: policy) { _ in }
        default:
            DirectWorkerLaunchAdmission.admitApprovedPlanRun(task, modelContext: harness.context)
            await worker.executeApprovedPlan(task: task, plan: plan,
                mode: route == "final_only" ? .nextStep : .fullPlan, executionRequestID: requestID,
                modelContext: harness.context, executionPolicy: policy) { _ in }
        }
        #expect(fake.receivedPrompts.isEmpty)
        #expect(task.runs.isEmpty)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: harness.context) == nil)
        #expect(task.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(task.events.contains { $0.eventType == TaskEventTypes.System.error })
        #expect(foreignRequest == nil || foreignRequest?.state == .admitted)
    }

    @Test("An omitted request ID still permits direct Work final validation")
    func directWorkValidationDoesNotReadARequest() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Validate the workspace", model: "claude-sonnet-4-6")
        let marker = harness.workspaceURL.appendingPathComponent("direct-command-ran")
        try ".PHONY: test\ntest:\n\t@printf 'ran\\n' >> direct-command-ran\n"
            .write(to: harness.workspaceURL.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let plan = TaskPlanPayload(title: "Synthetic plan", goal: task.goal,
            steps: [.init(id: "check", title: "Check", status: .done)],
            validationContract: .init(assertions: [.init(id: "command", description: "Synthetic command",
                method: .command, command: "make test")]))
        var reads = 0
        let fake = FakeAgentProcessRunner()
        let worker = makeWorker(fake, runtime: .claudeCode, root: harness.rootURL, requestReader: { _, _ in
            reads += 1
            throw FixtureError.read
        })
        DirectWorkerLaunchAdmission.admitApprovedPlanRun(task, modelContext: harness.context)
        await worker.executeApprovedPlan(task: task, plan: plan, mode: .nextStep,
            modelContext: harness.context) { _ in }
        #expect(reads == 0)
        #expect(task.status == .completed)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "ran\n")
        #expect(fake.receivedPrompts.isEmpty)
    }

    @Test("Frozen Consult rejects writable preparation before hooks or branch changes",
          arguments: ["hooks", "branch", "tests", "sandbox_off"])
    func rejectBeforePreparation(workflow: String) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6")
        try git(["init", "--initial-branch=fixture-main"], at: harness.workspaceURL)
        try git(["-c", "user.name=ASTRA Tests", "-c", "user.email=tests@example.invalid", "-c",
                 "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"], at: harness.workspaceURL)
        if workflow == "hooks" { task.templateHooksJSON = #"{"PreToolUse":[{"matcher":"Read","hooks":[]}]}"# }
        if workflow == "branch" { task.isolationStrategy = .gitBranch }
        if workflow == "tests" { task.validationStrategy = .runTests }
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let request = try submit(task, context: harness.context)
        let policy = admissionPolicy(request, task: task, enforcement: workflow == "sandbox_off" ? .off : .strict)
        // The accepted request, not today's composer selection, owns intent.
        TaskWorkspaceConsultationPolicy.apply(false, to: task)
        let fake = FakeAgentProcessRunner()
        let worker = makeWorker(fake, runtime: .claudeCode, root: harness.rootURL)
        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: harness.context)
        await worker.execute(task: task, modelContext: harness.context,
            existingStartEventID: request.messageEventID, executionRequestID: request.id,
            executionPolicy: policy) { _ in }

        #expect(fake.receivedPrompts.isEmpty)
        #expect(task.status == .failed)
        #expect(request.state == .failed)
        #expect(request.terminalReason == "consultation_requires_read_only_workspace")
        #expect(!FileManager.default.fileExists(atPath: harness.workspaceURL.appendingPathComponent(".claude").path))
        let head = try String(contentsOf: harness.workspaceURL.appendingPathComponent(".git/HEAD"), encoding: .utf8)
        #expect(head == "ref: refs/heads/fixture-main\n")
    }

    @Test("Command assertions cannot receive live admission or execute final-only validation",
          arguments: [TaskPlanExecutionMode.fullPlan, .nextStep])
    func rejectCommandPlan(mode: TaskPlanExecutionMode) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6")
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let marker = harness.workspaceURL.appendingPathComponent("assertion-ran")
        let plan = TaskPlanPayload(title: "Synthetic plan", goal: task.goal,
            steps: [.init(id: "explain", title: "Explain", status: mode == .nextStep ? .done : .pending)],
            validationContract: .init(assertions: [.init(id: "command", description: "Synthetic command",
                method: .command, command: "touch '\(marker.path)'")]))
        guard case .success(let submission) = ExecutionRequestSubmissionService.submitPlan(plan: plan,
            mode: mode, mutation: .existingTask, for: task, into: harness.context) else {
            Issue.record("Could not submit synthetic plan"); return
        }
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: harness.context))
        #expect(request.resourceClaims.first?.access == .exclusive)
        #expect(request.resourceClaims.first?.readConsistency == .live)
        // A request saved by the earlier implementation also receives an
        // exclusive lease, based on its immutable source plan.
        request.resourceClaimsJSON = TaskEvent.payloadString(TaskExecutionResourceClaimResolver.claims(for: task))
        let policy = admissionPolicy(request, task: task)
        #expect(policy.workspaceAccessOverride == .exclusive)
        #expect(policy.admittedResourceClaims?.contains(where: \.isLiveWorkspaceReader) == false)
        let writer = AgentTask(title: "Writer", goal: "Write", workspace: task.workspace)
        let writerClaims = TaskExecutionResourceBroker.lockClaims(for: TaskExecutionResourceClaimResolver.claims(for: writer),
            taskID: writer.id, requestID: nil, runMode: "fixture")
        #expect(!TaskExecutionResourceBroker.canAcquire(policy.admittedResourceClaims ?? [], active: writerClaims))
        TaskWorkspaceConsultationPolicy.apply(false, to: task)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        DirectWorkerLaunchAdmission.admitApprovedPlanRun(task, modelContext: harness.context)
        let fake = FakeAgentProcessRunner()
        await makeWorker(fake, runtime: .claudeCode, root: harness.rootURL).executeApprovedPlan(task: task,
            plan: plan, mode: mode, executionRequestID: request.id, modelContext: harness.context,
            executionPolicy: policy) { _ in }
        #expect(fake.receivedPrompts.isEmpty)
        #expect(request.state == .failed)
        #expect(request.terminalReason == "consultation_plan_commands")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Consult does not claim a concurrent writer's files but retains its task outputs", arguments: [true, false])
    func inferredWorkspaceOwnership(consultation: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .codexCLI, goal: "Explain the workspace", model: "gpt-5.4", tokenBudget: 0)
        try git(["init"], at: harness.workspaceURL)
        TaskWorkspaceConsultationPolicy.apply(consultation, to: task)
        let request = try submit(task, context: harness.context)
        let changed = harness.workspaceURL.appendingPathComponent("concurrent-writer.swift")
        let output = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder).appendingPathComponent("answer.md")
        let fake = FakeAgentProcessRunner()
        fake.streamLines = [#"{"type":"item.completed","item":{"type":"agent_message","text":"The workspace contains a synthetic example."}}"#]
        fake.onLaunch = { _, _ in
            // This write represents a separate task during the provider turn;
            // the consultation provider emits no file-change tool events.
            do {
                try "let siblingValue = 42\n".write(to: changed, atomically: true, encoding: .utf8)
                try "Synthetic answer\n".write(to: output, atomically: true, encoding: .utf8)
            } catch { Issue.record("Synthetic writer failed: \(error)") }
        }
        let worker = makeWorker(fake, runtime: .codexCLI, root: harness.rootURL)
        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: harness.context)
        await worker.execute(task: task, modelContext: harness.context,
            existingStartEventID: request.messageEventID, executionRequestID: request.id,
            executionPolicy: admissionPolicy(request, task: task)) { _ in }
        #expect(fake.receivedPrompts.count == 1)
        let run = try #require(task.runs.last)
        #expect(run.fileChanges.contains { $0.path == changed.path } == !consultation)
        #expect(task.artifacts.contains { $0.path == changed.path } == !consultation)
        #expect(run.allFileChanges.contains {
            $0.kind.isObserved
                && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == output.resolvingSymlinksInPath().path
        })
        #expect(task.artifacts.contains { $0.path == output.path })
        // Reloaded discovery uses the originating request even after the
        // composer changes and must not recreate the sibling artifact.
        TaskWorkspaceConsultationPolicy.apply(false, to: task)
        #expect(TaskOutputDiscovery.files(for: task, run: run).contains { $0.path == changed.path } == !consultation)
        // Recovery may clear current-attempt fields while the source event
        // remains attached to the old run. Historical discovery still belongs
        // to that request's immutable access, not the current composer mode.
        request.runID = nil
        request.startedAt = nil
        request.admittedAt = nil
        try harness.context.save()
        #expect(TaskHistoryRead.event(id: request.messageEventID, in: task)?.run?.id == run.id)
        #expect(TaskOutputDiscovery.files(for: task, run: run).contains { $0.path == changed.path } == !consultation)
    }

    @Test("A plan updated during Consult stays read-only, and Work can retry final validation", arguments: [false, true])
    func providerPlanUpdateCannotWidenValidationAccess(retryInWork: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6", tokenBudget: 0)
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let plan = TaskPlanPayload(title: "Synthetic plan", goal: task.goal,
            steps: [.init(id: "explain", title: "Explain", likelyTools: ["Read"])])
        guard case .success(let submission) = ExecutionRequestSubmissionService.submitPlan(plan: plan,
            mode: .fullPlan, mutation: .existingTask, for: task, into: harness.context) else {
            Issue.record("Could not submit synthetic plan"); return
        }
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: harness.context))
        let policy = admissionPolicy(request, task: task)
        #expect(policy.workspaceAccessOverride == .shared)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        DirectWorkerLaunchAdmission.admitApprovedPlanRun(task, modelContext: harness.context)
        let marker = harness.workspaceURL.appendingPathComponent("late-assertion-ran")
        try ".PHONY: test\ntest:\n\t@printf 'validated\\n' >> late-assertion-ran\n"
            .write(to: harness.workspaceURL.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let fake = FakeAgentProcessRunner()
        fake.streamLines = [#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The workspace contains synthetic files."}]}}"#]
        fake.onLaunch = { _, _ in
            var updated = plan
            updated.steps[0].status = .done
            updated.validationContract = .init(assertions: [.init(id: "late-command",
                description: "Command added during the turn", method: .command, command: "make test")])
            TaskPlanService.recordUpdated(updated, task: task, modelContext: harness.context)
            // Exercise the immutable request when the live composer changes.
            TaskWorkspaceConsultationPolicy.apply(false, to: task)
        }
        await makeWorker(fake, runtime: .claudeCode, root: harness.rootURL).executeApprovedPlan(task: task,
            plan: plan, executionRequestID: request.id, modelContext: harness.context,
            executionPolicy: policy) { _ in }
        #expect(fake.receivedPrompts.count == 1)
        #expect(request.state == .failed)
        #expect(request.terminalReason == "consultation_plan_commands")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        guard retryInWork else { return }

        let originalRun = try #require(task.runs.first)
        #expect(try TaskTurnRequestRepository.origin(for: task, runID: originalRun.id, in: harness.context)?.id == request.id)
        let completedPlan = try #require(TaskPlanService.reconstruct(for: task).plan)
        #expect(TaskPlanService.nextExecutableStep(in: completedPlan) == nil)
        TaskWorkspaceConsultationPolicy.apply(false, to: task)
        guard case .success(let retry) = ExecutionRequestSubmissionService.submitPlan(plan: completedPlan,
            mode: .nextStep, mutation: .existingTask, for: task, into: harness.context) else {
            Issue.record("Could not submit the Work final-validation retry"); return
        }
        let workRequest = try #require(try TaskTurnRequestRepository.request(id: retry.requestID, in: harness.context))
        let workPolicy = admissionPolicy(workRequest, task: task)
        #expect(workPolicy.workspaceAccessOverride == .exclusive)
        #expect(workRequest.resourceClaims.allSatisfy { $0.readConsistency != .live })
        _ = TaskTurnRequestStateMachine.transition(workRequest, to: .admitted)
        // The accepted Work request stays authoritative if the composer changes.
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        DirectWorkerLaunchAdmission.admitApprovedPlanRun(task, modelContext: harness.context)
        await makeWorker(fake, runtime: .claudeCode, root: harness.rootURL).executeApprovedPlan(task: task,
            plan: completedPlan, mode: .nextStep, executionRequestID: workRequest.id, modelContext: harness.context,
            executionPolicy: workPolicy) { _ in }
        #expect(task.status == .completed)
        #expect(workRequest.terminalReason != "consultation_plan_commands")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "validated\n")
        #expect(fake.receivedPrompts.count == 1)
        #expect(task.runs.count == 1 && task.runs.first?.id == originalRun.id)
        #expect(request.state == .failed && request.terminalReason == "consultation_plan_commands")
    }

    @Test("Native Consult resumes retain the live-read restrictions")
    func nativeResumeRetainsGuidance() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6", tokenBudget: 0)
        task.status = .completed
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let fake = FakeAgentProcessRunner()
        fake.streamLines = [
            #"{"type":"system","subtype":"init","session_id":"consult-session","model":"claude-sonnet-4-6"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The workspace contains synthetic files."}]}}"#
        ]
        let worker = makeWorker(fake, runtime: .claudeCode, root: harness.rootURL)
        for _ in 0..<2 {
            guard case .success(let submission) = ExecutionRequestSubmissionService.submitFollowUp(
                message: "Explain the workspace", for: task, into: harness.context) else {
                Issue.record("Could not submit synthetic follow-up"); return
            }
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: harness.context))
            _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
            DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: harness.context)
            await worker.continueSession(task: task, message: "Explain the workspace",
                existingMessageEventID: submission.eventID, turnRequestID: request.id, modelContext: harness.context,
                executionPolicy: admissionPolicy(request, task: task)) { _ in }
        }
        #expect(fake.receivedPrompts.count == 2)
        #expect(fake.receivedNativeSessions.last == "consult-session")
        for prompt in fake.receivedPrompts {
            #expect(prompt.contains(TaskWorkspaceConsultationPolicy.providerGuidance))
        }
    }

    private func submit(_ task: AgentTask, context: ModelContext) throws -> TaskTurnRequest {
        guard case .success(let submission) = ExecutionRequestSubmissionService.submitInitial(for: task, into: context) else {
            throw FixtureError.submission
        }
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        return request
    }

    private func admissionPolicy(_ request: TaskTurnRequest, task: AgentTask,
                                 enforcement: ExecutionSandboxEnforcement = .strict) -> AgentRuntimeExecutionPolicy {
        let claims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "fixture", sandboxEnforcement: enforcement)
        return AgentRuntimeExecutionPolicy.default.withResourceAdmission(
            workspaceAccess: TaskExecutionResourceAdmissionPolicy.workspaceAccess(from: claims),
            sandboxEnforcement: enforcement, claims: claims)
    }

    private func makeWorker(_ fake: FakeAgentProcessRunner, runtime: AgentRuntimeID, root: URL,
                            requestReader: @escaping RuntimeExecutionAdmission.RequestReader = {
                                try TaskTurnRequestRepository.request(id: $0, in: $1)
                            }) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker(processRunner: fake, providerSettingsSnapshotProvider: { .headlessScenario },
            executionRequestReader: requestReader)
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.setExecutablePath("/bin/sh", for: runtime)
        worker.setHomeDirectory(root.appendingPathComponent("provider-home").path, for: runtime)
        return worker
    }

    private func git(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private enum FixtureError: Error { case submission, read }
}
