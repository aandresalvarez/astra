import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Task completion policy")
@MainActor
struct TaskCompletionPolicyTests {
    @Test("Requested PR failure blocks task completion but preserves local run completion")
    func requestedPullRequestFailureBlocksCompletion() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Implement the fix and create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.use,
            payload: "Using tool: Bash: gh pr create --draft",
            run: run
        ))
        context.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.Tool.resultFailed,
            payload: ToolResultFailurePayload(toolID: "tool_pr", message: "GitHub broker is read-only"),
            run: run
        ))
        try context.save()

        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .requiredExternalOutcome)
        #expect(decision.typedStopReason == .externalOutcomePending)
        #expect(decision.auditFields["outcome_kind"] == "github_pull_request")
    }

    @Test("Earlier PR failure remains a completion gate after an unrelated failure")
    func earlierPullRequestFailureRemainsCompletionGate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Implement the fix and create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.Tool.resultFailed,
            payload: ToolResultFailurePayload(
                toolID: "tool_pr",
                message: "HTTP 500",
                toolUseEvidence: "Using tool: Bash: gh pr create --draft"
            ),
            run: run
        ))
        context.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.Tool.resultFailed,
            payload: ToolResultFailurePayload(
                toolID: "tool_read",
                message: "File not found",
                toolUseEvidence: "Using tool: Read: /tmp/missing"
            ),
            run: run
        ))
        try context.save()

        let failure = try #require(
            TaskExternalOutcomeFailureClassifier.pendingGitHubPullRequestFailure(task: task, run: run)
        )

        #expect(failure.sourceEventID == task.events.first {
            $0.type == TaskEventTypes.Tool.resultFailed.rawValue
                && ToolResultFailurePayload.decode(from: $0.payload)?.toolID == "tool_pr"
        }?.id)
    }

    @Test("Failed result is correlated to its own tool use")
    func failedResultUsesMatchingToolEvidence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Implement the fix and create a pull request")
        let run = TaskRun(task: task)
        let recordingState = AgentEventRecordingState()
        context.insert(task)
        context.insert(run)

        AgentEventRecorder.recordCopilotEvent(
            .toolUse(name: "bash", id: "tool_pr", inputSummary: "gh pr create --draft"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        AgentEventRecorder.recordCopilotEvent(
            .toolUse(name: "read", id: "tool_read", inputSummary: "/tmp/notes"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        AgentEventRecorder.recordCopilotEvent(
            .toolResult(id: "tool_pr", content: "HTTP 500", isError: true),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        try context.save()

        let failure = TaskExternalOutcomeFailureClassifier.pendingGitHubPullRequestFailure(
            task: task,
            run: run
        )

        #expect(failure != nil)
    }

    @Test("Ask owns requested PR publication after successful local work")
    func askOwnsRequestedPullRequestPublication() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Implement the fix and create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        try context.save()

        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(
            task: task,
            run: run,
            permissionPolicy: .restricted
        )

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .requiredExternalOutcome)
        #expect(decision.typedStopReason == .externalOutcomePending)
        #expect(decision.auditFields["publication_owner"] == "astra")
        #expect(decision.auditFields["source_event_id"] == "none")
    }

    @Test("Auto leaves successful requested PR publication provider-owned")
    func autoLeavesRequestedPullRequestPublicationProviderOwned() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Implement the fix and create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        try context.save()

        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(
            task: task,
            run: run,
            permissionPolicy: .autonomous
        )

        #expect(decision.canComplete)
        #expect(decision.gate == .manualArtifactRequirement)
        #expect(decision.auditFields["publication_owner"] == nil)
    }

    @Test("validation contract policy blocks failed required assertions")
    func validationContractPolicyBlocksFailedRequiredAssertions() {
        let evaluation = TaskValidationContractEvaluation(
            didRun: true,
            outcome: .failed,
            canComplete: false,
            summary: "Validation contract failed.",
            failedRequiredAssertionIDs: ["proof"]
        )

        let decision = TaskCompletionPolicy.decide(validationContract: evaluation)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .validationContract)
        #expect(decision.stopReason == "validation_contract_failed")
        #expect(decision.typedStopReason == .validationContractFailed)
        #expect(decision.userVisibleMessage == "Validation contract failed.")
        #expect(decision.auditFields["outcome"] == "failed")
    }

    @Test("deliverable policy maps missing artifacts to no usable result")
    func deliverablePolicyMapsMissingArtifactsToNoUsableResult() {
        let result = TaskDeliverableVerificationResult(
            version: 1,
            profile: .standaloneWebArtifact,
            level: .noArtifact,
            status: "failed",
            canComplete: false,
            requiresHumanReview: false,
            summary: "No artifact found.",
            checks: [],
            evidencePaths: [],
            runID: UUID(),
            verifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .deliverableVerification)
        #expect(decision.stopReason == "no_usable_result")
        #expect(decision.typedStopReason == .noUsableResult)
        #expect(decision.userVisibleMessage == "No artifact found.")
    }

    @Test("inferred validation policy uses inferred stop reason")
    func inferredValidationPolicyUsesInferredStopReason() {
        let evaluation = TaskValidationContractEvaluation(
            didRun: true,
            outcome: .failed,
            canComplete: false,
            summary: "Required inferred proof failed.",
            failedRequiredAssertionIDs: ["artifact-1"]
        )

        let decision = TaskCompletionPolicy.decide(inferredValidation: evaluation)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .inferredValidation)
        #expect(decision.stopReason == "inferred_validation_failed")
        #expect(decision.typedStopReason == .inferredValidationFailed)
        #expect(decision.userVisibleMessage == "Automatic verification failed: Required inferred proof failed.")
    }

    @Test("Completion blocked event payload encodes typed decision context")
    func completionBlockedEventPayloadEncodesTypedDecisionContext() throws {
        let decision = TaskCompletionPolicyDecision.block(
            gate: .manualArtifactRequirement,
            stopReason: .noUsableResult,
            userVisibleMessage: "Missing artifact.",
            auditFields: ["has_artifact": "false"]
        )

        let payload = TaskCompletionBlockedEventPayload(decision: decision)
        let encoded = try #require(tryEncodedPayload(payload))
        let event = TaskEvent(
            task: AgentTask(title: "Payload", goal: "Encode typed payload"),
            eventType: TaskEventTypes.System.error,
            payload: encoded
        )

        let decoded = try #require(tryDecodedPayload(event, as: TaskCompletionBlockedEventPayload.self))
        #expect(decoded == payload)
        #expect(decoded.gate == "manual_artifact_requirement")
        #expect(decoded.stopReason == "no_usable_result")
        #expect(decoded.auditFields["has_artifact"] == "false")
    }

    @Test("manual completion policy blocks standalone artifact tasks without artifacts")
    func manualCompletionPolicyBlocksStandaloneArtifactTasksWithoutArtifacts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(
            title: "Web page",
            goal: "write a web page with html and javascript",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()

        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .manualArtifactRequirement)
        #expect(decision.stopReason == "no_usable_result")
        #expect(decision.userVisibleMessage?.contains("standalone file artifact") == true)
    }

    @Test("missing deliverable blocks before Ask pull request publication")
    func missingDeliverablePrecedesPullRequestPublication() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(
            title: "Publish web page",
            goal: "Write a web page with HTML and JavaScript, then create a pull request",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()

        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(
            task: task,
            run: run,
            permissionPolicy: .restricted
        )

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .manualArtifactRequirement)
        #expect(decision.typedStopReason == .noUsableResult)
    }

    @Test("Artifact-first Ask completion queues and later presents the PR gate")
    func artifactApprovalRechecksQueuedPullRequestOutcome() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("artifact-pr-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: root.path)
        let task = AgentTask(
            title: "Publish web page",
            goal: "Write a web page with HTML and JavaScript, then create a pull request",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let completed = TaskSuccessfulCompletionService.apply(
            task: task,
            run: run,
            modelContext: context,
            successPayload: "Local work finished.",
            permissionPolicy: .restricted
        )
        try context.save()

        #expect(!completed)
        #expect(run.typedStopReason == .noUsableResult)
        #expect(task.events.contains {
            $0.run?.id == run.id && $0.type == TaskExternalOutcomeEventTypes.publicationRequested
        })

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        let coordinator = TaskLifecycleCoordinator(
            modelContext: context,
            taskQueue: TaskQueue()
        )
        coordinator.approveTask(task)

        #expect(task.status == .pendingUser)
        #expect(run.typedStopReason == .externalOutcomePending)
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
            task: task,
            run: run
        ) != nil)
    }

    @Test("publication receipt cannot complete a task whose deliverable is missing")
    func publicationReceiptDoesNotBypassMissingDeliverable() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(
            title: "Publish web page",
            goal: "Write a web page with HTML and JavaScript, then create a pull request",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()

        let completed = TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task,
            run: run,
            modelContext: context
        )

        #expect(!completed)
        #expect(task.status == .pendingUser)
        #expect(run.typedStopReason == .noUsableResult)
    }

    @Test("publication receipt completes the run and clears the pending external outcome")
    func publicationReceiptClearsExternalOutcomeStopReason() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(
            title: "Publish the code change",
            goal: "Create a pull request for the completed code change",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        run.recordExternalOutcomePending()
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()

        let completed = TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task,
            run: run,
            modelContext: context
        )

        #expect(completed)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.typedStopReason == .completed)
        #expect(run.completedAt != nil)
    }

    @Test("manual completion policy names missing explicit deliverables")
    func manualCompletionPolicyNamesMissingExplicitDeliverables() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("manual-completion-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: root)
        let task = AgentTask(
            title: "Results",
            goal: """
            Final deliverables:
            - ./results.txt
            """,
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()

        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .manualArtifactRequirement)
        #expect(decision.stopReason == "no_usable_result")
        #expect(decision.userVisibleMessage?.contains("Missing explicitly requested deliverable file: results.txt.") == true)
        #expect(decision.userVisibleMessage?.contains("standalone file artifact") == false)
    }

    @Test("temporary file cleanup does not trigger a missing deliverable gate")
    func temporaryFileCleanupDoesNotTriggerMissingDeliverableGate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(
            title: "Workspace write-concurrency probe test",
            goal: "Create a temporary file named astra-concurrency-probe.txt containing a timestamp, verify it, and then remove it."
        )
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        try context.save()

        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)

        #expect(!decision.shouldBlockCompletion)
        #expect(decision.gate == .manualArtifactRequirement)
        #expect(decision.auditFields["requires_artifact"] == "false")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
    }

    private func tryEncodedPayload<T: Encodable>(_ payload: T) -> String? {
        switch TaskEvent.encodePayload(payload) {
        case .success(let encoded):
            encoded
        case .failure:
            nil
        }
    }

    private func tryDecodedPayload<T: Decodable>(_ event: TaskEvent, as type: T.Type) -> T? {
        switch event.decodePayload(as: type, expecting: TaskEventTypes.System.error) {
        case .success(let payload):
            payload
        case .failure:
            nil
        }
    }
}
