import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeValidationServiceContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Validation service")
@MainActor
struct ValidationServiceTests {
    @Test("validation contract command pass records assertion and contract events")
    func validationContractCommandPasses() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run a proof command", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-pass",
                    description: "Command exits zero",
                    method: .command,
                    command: "true"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionStarted })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
    }

    @Test("validation contract command failure blocks completion")
    func validationContractCommandFailureBlocksCompletion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation Failure", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run a failing proof command", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a failing proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-fails",
                    description: "Command exits zero",
                    method: .command,
                    command: "false"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["command-fails"])
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractFailed })
        let correctiveEvent = try #require(task.events.first { $0.type == TaskCorrectiveEventTypes.stepCreated })
        #expect(correctiveEvent.payload.contains("command-fails"))
        #expect(correctiveEvent.payload.contains("Fix the work until this command exits 0"))
    }

    @Test("validation contract artifact check resolves task output folder paths")
    func validationContractArtifactCheckUsesTaskFolder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Validation", primaryPath: root)
        let task = AgentTask(title: "Validate artifact", goal: "Require an output artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "report".write(
            toFile: (taskFolder as NSString).appendingPathComponent("report.md"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Require an output artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "report-exists",
                    description: "Report exists",
                    method: .artifact,
                    path: "report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("report.md") })
    }

    @Test("failed validation creates one corrective item with auditable lifecycle")
    func failedValidationCreatesOneCorrectiveItemWithAuditableLifecycle() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Corrective", primaryPath: root)
        let task = AgentTask(title: "Corrective validation", goal: "Create a failing correction", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Require corrective work",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "must-pass",
                    description: "Command passes",
                    method: .command,
                    command: "false"
                )
            ])
        )

        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)
        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        let proposedEvents = task.events.filter { $0.type == TaskCorrectiveEventTypes.stepCreated }
        #expect(proposedEvents.count == 1)
        let record = try #require(TaskCorrectiveWorkService.openCorrectiveSteps(for: task).first)
        let correctiveStepID = TaskCorrectiveWorkService.normalizedCorrectiveStepID(record.payload)

        var state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let corrective = try #require(state.correctiveWork?.first)
        #expect(corrective.correctiveStepID == correctiveStepID)
        #expect(corrective.status == "proposed")
        #expect(corrective.failedAssertionID == "must-pass")
        #expect(state.nextLikelyAction?.contains("failed assertion must-pass") == true)
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Corrective work:"))
        #expect(prompt.contains("must-pass"))

        let approved = try #require(TaskCorrectiveWorkService.approveStep(
            task: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(approved.status == "approved")
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepApproved })

        let child = try #require(TaskCorrectiveWorkService.createCorrectiveTask(
            from: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(child.goal.contains("must-pass"))
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.taskCreated && $0.payload.contains(child.id.uuidString) })

        let dismissed = try #require(TaskCorrectiveWorkService.dismissStep(
            task: task,
            correctiveStepID: correctiveStepID,
            reason: "Handled in a different task",
            modelContext: context
        ))
        #expect(dismissed.status == "dismissed")
        #expect(dismissed.dismissedReason == "Handled in a different task")
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepDismissed })

        state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let finalCorrective = try #require(state.correctiveWork?.first)
        #expect(finalCorrective.status == "dismissed")
        #expect(finalCorrective.correctiveTaskID == child.id.uuidString)
        let markdown = try String(
            contentsOfFile: (TaskWorkspaceAccess(task: task).taskFolder as NSString)
                .appendingPathComponent(TaskContextStateManager.markdownFileName),
            encoding: .utf8
        )
        #expect(markdown.contains("## Corrective Work"))
        #expect(markdown.contains("Handled in a different task"))
    }

    @Test("browser behavior assertion passes with deterministic evidence")
    func browserBehaviorAssertionPassesWithDeterministicEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Behavior", primaryPath: root)
        let task = AgentTask(title: "Browser behavior", goal: "Validate rendered artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try """
        <html><head><title>Demo</title></head><body><h1>Checkout Ready</h1></body></html>
        """.write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Browser proof",
            goal: "Validate rendered artifact",
            steps: [TaskPlanPayloadStep(id: "browser", title: "Browser")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "browser-visible",
                    description: "Checkout Ready",
                    method: .browserBehavior,
                    path: "index.html",
                    evidenceQuery: "Checkout Ready"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.started })
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.evidenceAttached })
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.passed })
        let assertionEvent = try #require(task.events.first {
            $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("browser-visible")
        })
        #expect(assertionEvent.payload.contains("validation-evidence"))
        let state = try #require(TaskContextStateManager.load(taskFolder: taskFolder))
        let assertion = try #require(state.validationContract?.assertions.first { $0.id == "browser-visible" })
        #expect(assertion.sourcePointers.contains { $0.kind == "validation_evidence" && $0.path?.contains("browser-visible-behavior.json") == true })
    }

    @Test("browser behavior assertion failure blocks required contract")
    func browserBehaviorAssertionFailureBlocksRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Behavior Failure", primaryPath: root)
        let task = AgentTask(title: "Browser behavior", goal: "Validate rendered artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Still Loading</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Browser proof",
            goal: "Validate rendered artifact",
            steps: [TaskPlanPayloadStep(id: "browser", title: "Browser")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "browser-missing",
                    description: "Checkout Ready",
                    method: .browserBehavior,
                    path: "index.html",
                    evidenceQuery: "Checkout Ready"
                )
            ])
        )

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["browser-missing"])
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.failed && $0.payload.contains("expected_text_missing") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed && $0.payload.contains("expected_text_missing") })
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepCreated && $0.payload.contains("browser-missing") })
    }

    @Test("verifier assertion pass satisfies required contract")
    func verifierAssertionPassSatisfiesRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeCopilot = try fakeCopilotUtility(in: root, output: "PASS\nReviewed assertion verifier-pass.")
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verifier Pass", primaryPath: root)
        let task = AgentTask(title: "Verifier", goal: "Review independently", workspace: workspace)
        let run = TaskRun(task: task)
        run.output = "Worker says the change is complete."
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Verifier plan",
            goal: "Review independently",
            steps: [TaskPlanPayloadStep(id: "review", title: "Review")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "verifier-pass",
                    description: "Independent verifier approves the work",
                    method: .verifier
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            verifierRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: (root as NSString).appendingPathComponent("copilot-home")
            )
        )

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.started })
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.completed && $0.payload.contains("\"result\":\"pass\"") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionReviewed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("verifier-pass") })
    }

    @Test("verifier assertion failure blocks required contract")
    func verifierAssertionFailureBlocksRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeCopilot = try fakeCopilotUtility(in: root, output: "FAIL\nMissing expected behavior evidence.")
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verifier Fail", primaryPath: root)
        let task = AgentTask(title: "Verifier", goal: "Review independently", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Verifier plan",
            goal: "Review independently",
            steps: [TaskPlanPayloadStep(id: "review", title: "Review")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "verifier-fail",
                    description: "Independent verifier approves the work",
                    method: .verifier
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            verifierRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: (root as NSString).appendingPathComponent("copilot-home")
            )
        )

        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["verifier-fail"])
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.completed && $0.payload.contains("\"result\":\"fail\"") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionReviewed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed && $0.payload.contains("verifier_failed_assertion") })
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepCreated && $0.payload.contains("verifier-fail") })
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-validation-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func fakeCopilotUtility(in root: String, output: String) throws -> URL {
        let fakeCopilot = URL(fileURLWithPath: root).appendingPathComponent("copilot")
        let escaped = output
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(escaped)"}}'
        exit 0
        """
        try script.write(to: fakeCopilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCopilot.path)
        return fakeCopilot
    }
}
