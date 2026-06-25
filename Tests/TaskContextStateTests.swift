import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeTaskContextStateContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task context state")
@MainActor
struct TaskContextStateTests {
    @Test("loadResult reports missing current-state file")
    func loadResultReportsMissingCurrentStateFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = TaskContextStateManager.loadResult(taskFolder: root)

        #expect(result.status == .missingFile)
        #expect(result.path.hasSuffix(TaskContextStateManager.jsonFileName))
        #expect(result.state == nil)
        #expect(!result.didLoad)
    }

    @Test("loadResult reports malformed current-state JSON")
    func loadResultReportsMalformedJSON() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = (root as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)

        let result = TaskContextStateManager.loadResult(taskFolder: root)

        #expect(result.status == .decodeFailed)
        #expect(result.path == path)
        #expect(result.state == nil)
        #expect(result.errorDescription?.contains("current:") == true)
        #expect(result.decodeDiagnostic?.status == .decodeFailed)
        #expect(result.decodeDiagnostic?.typeName == "TaskContextState")
        #expect(result.decodeDiagnostic?.errorDescription?.isEmpty == false)
    }

    @Test("loadResult reports structured current-state coding path diagnostics")
    func loadResultReportsStructuredCodingPathDiagnostics() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = (root as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)
        let encoded = try JSONEncoder().encode(minimalState())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["updatedAt"] = 42
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try malformed.write(to: URL(fileURLWithPath: path))

        let result = TaskContextStateManager.loadResult(taskFolder: root)

        #expect(result.status == .decodeFailed)
        #expect(result.state == nil)
        #expect(result.decodeDiagnostic?.status == .decodeFailed)
        #expect(result.decodeDiagnostic?.codingPath == "updatedAt")
        #expect(result.errorDescription?.contains("current:") == true)
    }

    @Test("saveState returns structured success and writes both state files")
    func saveStateReturnsStructuredSuccess() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = TaskContextStateManager.saveState(minimalState(), taskFolder: root)

        #expect(result.status == .saved)
        #expect(result.didSave)
        #expect(FileManager.default.fileExists(atPath: result.jsonPath))
        #expect(FileManager.default.fileExists(atPath: result.markdownPath))
        #expect(TaskContextStateManager.loadResult(taskFolder: root).status == .loadedCurrent)
    }

    @Test("saveState reports directory creation failures")
    func saveStateReportsDirectoryCreationFailure() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let filePath = (root as NSString).appendingPathComponent("not-a-directory")
        try "file".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = TaskContextStateManager.saveState(minimalState(), taskFolder: filePath)

        #expect(result.status == .createDirectoryFailed)
        #expect(!result.didSave)
        #expect(result.jsonPath.hasSuffix("/not-a-directory/\(TaskContextStateManager.jsonFileName)"))
        #expect(result.errorDescription?.isEmpty == false)
    }

    @Test("recording a run writes canonical JSON and markdown state")
    func recordsCurrentStateFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "State", primaryPath: root)
        let task = AgentTask(title: "Explore context", goal: "Explore whether ASTRA needs a context index", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        task.status = .completed
        run.status = .completed
        run.stopReason = "completed"
        run.output = "We decided to avoid vector databases and start with a current-state checkpoint."
        run.completedAt = Date()
        run.appendFileChange(StoredFileChange(from: FileChange(
            path: "\(root)/Astra/Services/Runtime/AgentPromptBuilder.swift",
            changeType: .edit,
            content: nil,
            oldString: nil,
            newString: nil,
            timestamp: Date()
        )))
        context.insert(run)

        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: "Should we use a vector database?"
        )

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.schemaVersion == 2)
        #expect(state.mode == .completed)
        #expect(state.startingRequest == "Explore whether ASTRA needs a context index")
        #expect(state.objective.currentObjective == "Explore whether ASTRA needs a context index")
        #expect(state.turns.count == 1)
        #expect(state.turns[0].ask == "Should we use a vector database?")
        #expect(state.turns[0].summary.contains("avoid vector databases"))
        #expect(state.filesChanged.contains { $0.hasSuffix("AgentPromptBuilder.swift") })
        #expect(state.changedFiles.contains { $0.path.hasSuffix("AgentPromptBuilder.swift") })
        #expect(state.sourcePointers.contains { $0.kind == "state_file" && $0.path?.hasSuffix(TaskContextStateManager.jsonFileName) == true })
        #expect(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)))
        #expect(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(TaskContextStateManager.markdownFileName)))
    }

    @Test("first user request wins over later edited task goal")
    func startingRequestUsesFirstConversationMessage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Original Request", primaryPath: root)
        let task = AgentTask(title: "Edited", goal: "Edited execution goal", workspace: workspace)
        let event = TaskEvent(task: task, type: "user.message", payload: "Original exploratory request")
        event.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(workspace)
        context.insert(task)
        context.insert(event)

        TaskContextStateManager.refresh(task: task)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.startingRequest == "Original exploratory request")
        #expect(state.currentObjective == "Edited execution goal")
        #expect(state.standingInstructions == nil) // no follow-ups → nil, not []
    }

    @Test("refresh discovers output artifacts without mutating artifact rows")
    func refreshDiscoversOutputArtifactsWithoutMutatingArtifactRows() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Discovered Artifact", primaryPath: root)
        let task = AgentTask(title: "Discover", goal: "Notice output files", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let reportPath = (folder as NSString).appendingPathComponent("report.md")
        try "# Report".write(toFile: reportPath, atomically: true, encoding: .utf8)

        TaskContextStateManager.refresh(task: task)

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.artifacts.contains { $0.path == reportPath && $0.type == "markdown" })
        #expect(task.artifacts.isEmpty)
    }

    @Test("turn numbering follows saved state and deterministic output paths")
    func turnNumberingUsesStateFloorAndFormattedOutputPath() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Turns", primaryPath: root)
        let task = AgentTask(title: "Number turns", goal: "Keep turn numbers stable", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let firstRun = TaskRun(task: task)
        firstRun.status = .completed
        firstRun.stopReason = "completed"
        firstRun.output = "first output"
        firstRun.completedAt = Date()
        context.insert(firstRun)
        TaskContextStateManager.recordTurn(task: task, run: firstRun, message: "first ask")

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let outputs = (folder as NSString).appendingPathComponent("outputs")
        try FileManager.default.createDirectory(atPath: outputs, withIntermediateDirectories: true)
        try "stale first output".write(
            toFile: (outputs as NSString).appendingPathComponent("turn_001.md"),
            atomically: true,
            encoding: .utf8
        )

        let secondRun = TaskRun(task: task)
        secondRun.status = .completed
        secondRun.stopReason = "completed"
        secondRun.output = "second output"
        secondRun.completedAt = Date()
        context.insert(secondRun)
        TaskContextStateManager.recordTurn(task: task, run: secondRun, message: "second ask")

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.turns.map(\.turn) == [1, 2])
        #expect(state.turns.map(\.outputFile) == ["outputs/turn_001.md", "outputs/turn_002.md"])
    }

    @Test("runtime browser shell failure is not reported as manual completion")
    func runtimeBrowserShellFailureIsNotReportedAsManualCompletion() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Runtime", primaryPath: root)
        let task = AgentTask(title: "Use browser", goal: "Inspect the browser", workspace: workspace)
        task.status = .pendingUser
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "provider_missing_browser_control_tool"
        run.output = "ASTRA blocked this browser task before launch because Copilot CLI cannot execute astra-browser."
        run.completedAt = Date()
        context.insert(run)
        TaskContextStateManager.recordTurn(task: task, run: run, message: "Inspect the browser")

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.mode == .blocked)
        #expect(state.verification.status == "failed")
        #expect(state.verification.summary == "provider_missing_browser_control_tool")
        #expect(state.verification.completionVerified == false)
        #expect(state.verification.status != "manual_completion")
    }

    @Test("completed run clears prior permission blocker from current state")
    func completedRunClearsPriorPermissionBlockerFromCurrentState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Permission Resume", primaryPath: root)
        let task = AgentTask(title: "Resume", goal: "who are you?", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        blockedRun.completedAt = Date()
        context.insert(blockedRun)
        context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: "Permission requested for tool: Bash(gh pr list *)",
            run: blockedRun
        ))
        TaskContextStateManager.recordTurn(task: task, run: blockedRun, message: "do i have open prs to review?")

        var blockedState = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(blockedState.mode == .blocked)
        #expect(blockedState.blockers.contains { $0.contains("gh pr list") })

        task.status = .completed
        let completedRun = TaskRun(task: task)
        completedRun.status = .completed
        completedRun.stopReason = "completed"
        completedRun.output = "You have one open PR to review."
        completedRun.completedAt = Date()
        context.insert(completedRun)
        TaskContextStateManager.recordTurn(
            task: task,
            run: completedRun,
            message: "ASTRA approved one-time runtime permission for this run: shell(gh:pr list *)"
        )

        blockedState = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(blockedState.mode == .completed)
        #expect(blockedState.blockers.isEmpty)
        #expect(blockedState.blockerFacts.isEmpty)
        #expect(blockedState.turns.first?.blockers.contains { $0.contains("gh pr list") } == true)
        #expect(blockedState.turns.last?.blockers.isEmpty == true)
    }

    @Test("follow-up user instructions are retained verbatim past the transcript window")
    func standingInstructionsRetainFollowUpDirectives() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Standing", primaryPath: root)
        let task = AgentTask(title: "Export", goal: "Build the export feature", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        // First message → pinned as startingRequest, excluded from standing list.
        let messages: [(Double, String)] = [
            (1, "Build the export feature"),
            (2, "Never modify the auth module"),
            (3, "ok proceed"),
            (4, "Output must be CSV not JSON"),
            (5, "no") // bare negation: a meaningful course-correction, must be kept
        ]
        for (ts, text) in messages {
            let event = TaskEvent(task: task, type: "user.message", payload: text)
            event.timestamp = Date(timeIntervalSince1970: ts)
            context.insert(event)
        }
        // Many later turns push the follow-ups out of the recent-transcript window;
        // the standing list reads all user messages regardless, so they survive.
        for index in 0..<20 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "progress \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(100 + index))
            context.insert(event)
        }

        TaskContextStateManager.refresh(task: task)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let instructions = (state.standingInstructions ?? []).map(\.text)
        #expect(instructions == ["Never modify the auth module", "Output must be CSV not JSON", "no"])
        #expect(!instructions.contains("Build the export feature")) // pinned as startingRequest
        #expect(!instructions.contains("ok proceed"))               // trimmed acknowledgement
        #expect(state.startingRequest == "Build the export feature")

        let prompt = try #require(TaskContextStateManager.promptContext(for: task))
        #expect(prompt.contains("Standing user instructions"))
        #expect(prompt.contains("Never modify the auth module"))
        #expect(prompt.contains("Output must be CSV not JSON"))
    }

    @Test("approved plans refresh state with explicit planning mode and approved goal")
    func planApprovalRecordsApprovedGoal() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Goal", primaryPath: root)
        let task = AgentTask(title: "Plan context", goal: "Improve ASTRA context handoff", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Context handoff v1",
            goal: "Add a local current-state checkpoint for ASTRA threads",
            steps: [
                TaskPlanPayloadStep(id: "state", title: "Add state file", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "prompt", title: "Inject state into prompts", likelyTools: ["Edit"])
            ]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.mode == .planning)
        #expect(state.approvedGoal == "Add a local current-state checkpoint for ASTRA threads")
        #expect(state.decisions.contains("Approved goal: Add a local current-state checkpoint for ASTRA threads"))
        #expect(state.nextLikelyAction == "Continue with plan step: Add state file")
    }

    @Test("unreconciled draft plan goal does not re-anchor the objective")
    func draftPlanGoalDivergenceDoesNotReanchorObjective() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Divergence", primaryPath: root)
        let task = AgentTask(title: "Goal drift", goal: "Original task goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let draftPlan = TaskPlanPayload(
            title: "Drifted plan",
            goal: "Drifted plan goal",
            steps: [TaskPlanPayloadStep(id: "s1", title: "Do work")]
        )
        // Draft only — not approved, and task.goal is not synced to the plan goal.
        TaskPlanService.recordCreated(draftPlan, task: task, modelContext: context)
        TaskContextStateManager.refresh(task: task)

        let draftState = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(draftState.currentObjective == "Original task goal")
        #expect(draftState.objective.currentObjective == "Original task goal")
        let note = try #require(draftState.objectiveDivergenceNote)
        #expect(note.contains("Drifted plan goal"))

        let prompt = try #require(TaskContextStateManager.promptContext(for: task))
        #expect(prompt.contains("Current objective: Original task goal"))
        #expect(prompt.contains("Objective reconciliation:"))

        // Approving reconciles the goal: the plan goal becomes authoritative and the note clears.
        TaskPlanService.recordApproved(draftPlan, task: task, modelContext: context)
        TaskContextStateManager.refresh(task: task)

        let approvedState = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(approvedState.currentObjective == "Drifted plan goal")
        #expect(approvedState.objectiveDivergenceNote == nil)
    }

    @Test("context capsule records validation contract summary")
    func contextCapsuleRecordsValidationContractSummary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Contract Plan", primaryPath: root)
        let task = AgentTask(title: "Plan contract", goal: "Prove completion before finishing", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Evidence gated plan",
            goal: "Require proof before completion",
            steps: [
                TaskPlanPayloadStep(id: "verify", title: "Verify the work", likelyTools: ["Bash"])
            ],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "focused-tests",
                    scope: .plan,
                    description: "Focused tests pass",
                    method: .command,
                    command: "swift test --filter TaskContextStateTests"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let contract = try #require(state.validationContract)
        #expect(contract.status == "not_verified")
        #expect(contract.assertionCount == 1)
        #expect(contract.requiredTotal == 1)
        #expect(contract.assertions[0].id == "focused-tests")
        #expect(contract.assertions[0].method == TaskValidationAssertionMethod.command.rawValue)
        #expect(contract.sourcePointers.contains { $0.kind == "event" && $0.summary.contains("validation.contract.created") })

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Validation contract: not_verified"))
        #expect(prompt.contains("focused-tests"))
        #expect(prompt.contains("Focused tests pass"))

        let markdown = try String(
            contentsOfFile: (TaskWorkspaceAccess(task: task).taskFolder as NSString)
                .appendingPathComponent(TaskContextStateManager.markdownFileName),
            encoding: .utf8
        )
        #expect(markdown.contains("## Validation Contract"))
        #expect(markdown.contains("focused-tests"))
    }

    @Test("context capsule marks optional-only validation contract passed after verification")
    func contextCapsuleMarksOptionalOnlyValidationContractPassed() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Optional Contract Plan", primaryPath: root)
        let task = AgentTask(title: "Optional contract", goal: "Capture advisory evidence", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let plan = TaskPlanPayload(
            title: "Optional evidence plan",
            goal: "Capture advisory proof before completion",
            steps: [
                TaskPlanPayloadStep(id: "verify", title: "Verify optional evidence", likelyTools: ["Bash"])
            ],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "advisory-proof",
                    scope: .plan,
                    description: "Advisory proof command passes",
                    method: .command,
                    required: false,
                    command: "true"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)
        #expect(result.canComplete)

        TaskContextStateManager.refresh(task: task)
        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let contract = try #require(state.validationContract)
        #expect(contract.status == "passed")
        #expect(contract.requiredTotal == 0)
        #expect(contract.requiredPassed == 0)
        #expect(contract.assertions.first?.status == "passed")
        #expect(contract.sourcePointers.contains { $0.kind == "event" && $0.summary.contains("validation.contract.passed") })
    }

    @Test("context capsule scopes validation contract outcome to current plan")
    func contextCapsuleScopesValidationContractOutcomeToCurrentPlan() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Scoped Contract Plan", primaryPath: root)
        let task = AgentTask(title: "Scoped contract", goal: "Avoid stale validation status", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let firstPlan = TaskPlanPayload(
            title: "First plan",
            goal: "Pass old proof",
            steps: [TaskPlanPayloadStep(id: "verify-old", title: "Verify old")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "old-proof",
                    description: "Old proof passes",
                    method: .command,
                    command: "true"
                )
            ])
        )
        TaskPlanService.recordCreated(firstPlan, task: task, modelContext: context)
        _ = await ValidationService.runContract(task: task, plan: firstPlan, run: run, modelContext: context)

        let secondPlan = TaskPlanPayload(
            title: "Second plan",
            goal: "Require new proof",
            steps: [TaskPlanPayloadStep(id: "verify-new", title: "Verify new")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "new-proof",
                    description: "New proof has not run",
                    method: .command,
                    command: "true"
                )
            ])
        )
        TaskPlanService.recordUpdated(secondPlan, task: task, modelContext: context)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let contract = try #require(state.validationContract)
        #expect(contract.status == "not_verified")
        #expect(contract.assertions.map(\.id) == ["new-proof"])
        #expect(contract.sourcePointers.allSatisfy { !$0.summary.contains(TaskValidationEventTypes.contractPassed) })
    }

    @Test("context capsule records task contract fields")
    func contextCapsuleRecordsTaskContractFields() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Contract", primaryPath: root)
        let task = AgentTask(title: "Contract", goal: "Keep task contract in compact state", workspace: workspace)
        task.constraints = ["Do not use provider-native memory as the source of truth"]
        task.acceptanceCriteria = ["Follow-up prompt includes the task contract"]
        task.testCommand = "swift test --filter TaskContextStateTests"
        context.insert(workspace)
        context.insert(task)

        TaskContextStateManager.refresh(task: task)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.constraints.map(\.text).contains("Do not use provider-native memory as the source of truth"))
        #expect(state.acceptanceCriteria.map(\.text).contains("Follow-up prompt includes the task contract"))
        #expect(state.testCommand == "swift test --filter TaskContextStateTests")
        #expect(state.verification.status == "not_verified")
        #expect(state.verification.command == "swift test --filter TaskContextStateTests")

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Context Capsule v2:"))
        #expect(prompt.contains("Treat this capsule as the authoritative compact task state"))
        #expect(prompt.contains("Do not use provider-native memory as the source of truth"))
        #expect(prompt.contains("Follow-up prompt includes the task contract"))
        #expect(prompt.contains("Test command: swift test --filter TaskContextStateTests"))
    }

    @Test("context capsule records failed validation evidence")
    func contextCapsuleRecordsFailedValidationEvidence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verification", primaryPath: root)
        let task = AgentTask(
            title: "Verification",
            goal: "Surface validation failures in compact state",
            workspace: workspace,
            validationStrategy: .runTests
        )
        task.testCommand = "swift test --filter VerificationRegressionTests"
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Implemented the check, but tests still fail."
        run.completedAt = Date()
        task.status = .failed
        context.insert(run)
        let validationEvent = TaskEvent(
            task: task,
            type: "error",
            payload: "Tests failed:\nVerificationRegressionTests.expectedContextCapsule",
            run: run
        )
        context.insert(validationEvent)

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Run validation")

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.mode == .blocked)
        #expect(state.verification.status == "failed")
        #expect(state.verification.strategy == ValidationStrategy.runTests.rawValue)
        #expect(state.verification.command == "swift test --filter VerificationRegressionTests")
        #expect(state.verification.completionVerified == false)
        #expect(state.verification.artifactStatus == "none recorded")
        #expect(state.verification.summary.contains("Tests failed"))
        #expect(state.verification.evidence.contains { $0.kind == "event" && $0.id == validationEvent.id.uuidString })
        #expect(state.blockerFacts.contains { $0.sourcePointers.contains { $0.id == validationEvent.id.uuidString } })

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Fix the validation failure", task: task)
        #expect(prompt.contains("Verification: failed via run_tests"))
        #expect(prompt.contains("Completion verified: no"))
        #expect(prompt.contains("Artifact status: none recorded"))
        #expect(prompt.contains("Verification command: swift test --filter VerificationRegressionTests"))
        #expect(prompt.contains("Verification evidence:"))
        #expect(prompt.contains(String(validationEvent.id.uuidString.prefix(8))))
        #expect(prompt.contains("Tests failed"))
    }

    @Test("context capsule records passed validation evidence")
    func contextCapsuleRecordsPassedValidationEvidence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verification Pass", primaryPath: root)
        let task = AgentTask(
            title: "Verification Pass",
            goal: "Surface passed validation in compact state",
            workspace: workspace,
            validationStrategy: .runTests
        )
        task.testCommand = "swift test --filter TaskContextStateTests"
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "All regression tests pass."
        run.completedAt = Date()
        task.status = .completed
        context.insert(run)
        let validationEvent = TaskEvent(
            task: task,
            type: "task.completed",
            payload: "Tests passed. 9 tests passed.",
            run: run
        )
        context.insert(validationEvent)

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Verify")

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.verification.status == "passed")
        #expect(state.verification.completionVerified)
        #expect(state.verification.evidence.contains { $0.kind == "event" && $0.id == validationEvent.id.uuidString })
        #expect(state.nextLikelyAction == "Review the result, approve it, or ask a follow-up.")

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Verification: passed via run_tests"))
        #expect(prompt.contains("Completion verified: yes"))
    }

    @Test("context capsule promotes artifact freshness into verification state")
    func contextCapsulePromotesArtifactFreshnessIntoVerificationState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Status", primaryPath: root)
        let task = AgentTask(
            title: "Artifact Status",
            goal: "Report artifact freshness in compact state",
            workspace: workspace,
            validationStrategy: .runTests
        )
        task.testCommand = "swift test --filter ArtifactStatusTests"
        context.insert(workspace)
        context.insert(task)

        let currentArtifactPath = (root as NSString).appendingPathComponent("current.html")
        try "<html>current</html>".write(toFile: currentArtifactPath, atomically: true, encoding: .utf8)
        let staleArtifactPath = (root as NSString).appendingPathComponent("missing.html")
        context.insert(Artifact(task: task, type: "html", path: currentArtifactPath))
        context.insert(Artifact(task: task, type: "html", path: staleArtifactPath))

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Generated and tested artifacts."
        run.completedAt = Date()
        task.status = .completed
        context.insert(run)
        let validationEvent = TaskEvent(
            task: task,
            type: "task.completed",
            payload: "Tests passed. Artifact status checked.",
            run: run
        )
        context.insert(validationEvent)

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Verify artifact freshness")

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.verification.status == "passed")
        #expect(state.verification.completionVerified)
        #expect(state.verification.artifactStatus == "1 current, 1 stale")
        #expect(state.artifacts.contains { $0.path == currentArtifactPath && !$0.isStale })
        #expect(state.artifacts.contains { $0.path == staleArtifactPath && $0.isStale })

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue from verification", task: task)
        #expect(prompt.contains("Completion verified: yes"))
        #expect(prompt.contains("Artifact status: 1 current, 1 stale"))
        #expect(prompt.contains("html v1 stale"))
    }

    @Test("context capsule merges duplicate persisted artifact paths")
    func contextCapsuleMergesDuplicatePersistedArtifactPaths() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Duplicate Artifacts", primaryPath: root)
        let task = AgentTask(
            title: "Duplicate artifact state",
            goal: "Render current state without crashing when artifacts share a path",
            workspace: workspace
        )
        context.insert(workspace)
        context.insert(task)

        let artifactPath = (root as NSString).appendingPathComponent("index.html")
        try "<html>current</html>".write(toFile: artifactPath, atomically: true, encoding: .utf8)
        let first = Artifact(task: task, type: "html", path: artifactPath, version: 1)
        first.createdAt = Date(timeIntervalSince1970: 1)
        let second = Artifact(task: task, type: "html", path: artifactPath, version: 2)
        second.createdAt = Date(timeIntervalSince1970: 2)
        context.insert(first)
        context.insert(second)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Generated the artifact twice for the same path."
        run.completedAt = Date()
        task.status = .completed
        context.insert(run)

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Refresh current state")

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let references = state.artifacts.filter { $0.path == artifactPath }
        #expect(references.count == 1)
        let reference = try #require(references.first)
        #expect(reference.version == 2)
        #expect(!reference.isStale)
        #expect(reference.sourcePointers.filter { $0.kind == "artifact" }.count == 2)
        #expect(state.verification.artifactStatus == "1 current")
    }

    @Test("context capsule normalizes legacy artifact paths without mutating rows")
    func contextCapsuleNormalizesLegacyArtifactPathsWithoutMutatingRows() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Legacy Artifact", primaryPath: root)
        let task = AgentTask(
            title: "Legacy artifact state",
            goal: "Render current state without duplicate artifact references",
            workspace: workspace
        )
        context.insert(workspace)
        context.insert(task)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let indexPath = (folder as NSString).appendingPathComponent("index.html")
        try "<html>current</html>".write(toFile: indexPath, atomically: true, encoding: .utf8)
        let relativePath = String(indexPath.dropFirst(root.count + 1))
        let legacy = Artifact(task: task, type: "html", path: relativePath, version: 2)
        legacy.type = "HTML"
        context.insert(legacy)
        task.artifacts.append(legacy)

        TaskContextStateManager.refresh(task: task)

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.artifacts.count == 1)
        let reference = try #require(state.artifacts.first)
        #expect(reference.path == indexPath)
        #expect(reference.type == "html")
        #expect(reference.version == 2)
        #expect(!reference.isStale)
        #expect(reference.sourcePointers.contains { $0.kind == "artifact" })
        #expect(reference.sourcePointers.contains { $0.kind == "task_output_file" })
        #expect(state.verification.artifactStatus == "1 current")
        #expect(legacy.path == relativePath)
        #expect(legacy.type == "HTML")
    }

    @Test("context capsule discovers task output files when provider metadata is missing")
    func contextCapsuleDiscoversTaskOutputFilesWhenProviderMetadataIsMissing() throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Discovered Artifact", primaryPath: root)
        let task = AgentTask(
            title: "Masterball artifact",
            goal: "Create a standalone puzzle page",
            workspace: workspace
        )
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-30)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Created .astra/tasks/\(String(task.id.uuidString.prefix(8)))/index.html."
        run.completedAt = Date().addingTimeInterval(30)
        task.status = .completed
        context.insert(run)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let indexPath = (folder as NSString).appendingPathComponent("index.html")
        try "<!doctype html><html><body>Masterball</body></html>".write(
            toFile: indexPath,
            atomically: true,
            encoding: .utf8
        )
        try "history".write(
            toFile: (folder as NSString).appendingPathComponent("session_history.md"),
            atomically: true,
            encoding: .utf8
        )
        let outsidePath = (outsideRoot as NSString).appendingPathComponent("outside.txt")
        try "outside".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: (folder as NSString).appendingPathComponent("outside.txt"),
            withDestinationPath: outsidePath
        )

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Create the page")

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.filesChanged.contains(indexPath))
        #expect(!state.filesChanged.contains { $0.hasSuffix("session_history.md") })
        #expect(!state.filesChanged.contains { $0.hasSuffix("outside.txt") })
        #expect(state.changedFiles.contains {
            $0.path == indexPath &&
                $0.changeType == "discovered" &&
                $0.sourcePointers.contains { $0.kind == "task_output_file" }
        })
        #expect(state.artifacts.contains {
            $0.path == indexPath &&
                $0.type == "html" &&
                !$0.isStale &&
                $0.sourcePointers.contains { $0.kind == "task_output_file" }
        })
        #expect(task.artifacts.isEmpty)
        #expect(state.verification.artifactStatus == "1 current")
        #expect(state.turns.first?.filesChanged.contains(indexPath) == true)

        TaskContextStateManager.refresh(task: task)
        #expect(task.artifacts.isEmpty)
    }

    @Test("artifact persistence canonicalizes relative and absolute task output paths")
    func artifactPersistenceCanonicalizesRelativeAndAbsoluteTaskOutputPaths() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Canonicalization", primaryPath: root)
        let task = AgentTask(
            title: "Create HTML",
            goal: "create a standalone html page",
            workspace: workspace
        )
        context.insert(workspace)
        context.insert(task)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let indexPath = (folder as NSString).appendingPathComponent("index.html")
        try "<!doctype html><html><body>Canonical</body></html>".write(
            toFile: indexPath,
            atomically: true,
            encoding: .utf8
        )
        let relativePath = String(indexPath.dropFirst(root.count + 1))
        let existing = Artifact(task: task, type: "html", path: relativePath, version: 1)
        context.insert(existing)
        task.artifacts.append(existing)

        let created = TaskArtifactPersistenceService.persistDiscoveredTaskOutputArtifacts([
            TaskOutputDiscoveredFile(
                path: indexPath,
                relativePath: "index.html",
                type: "html",
                modifiedAt: Date()
            )
        ], for: task, modelContext: context)

        #expect(created.isEmpty)
        #expect(existing.path == indexPath)
        #expect(task.artifacts.filter { $0.path == indexPath }.count == 1)
        #expect(task.artifacts.count == 1)
    }

    @Test("context capsule refresh repairs stale task output metadata")
    func contextCapsuleRefreshRepairsStaleTaskOutputMetadata() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Stale Capsule Repair", primaryPath: root)
        let task = AgentTask(
            title: "Repair task state",
            goal: "Create an artifact after state was written",
            workspace: workspace
        )
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-30)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Created index.html."
        run.completedAt = Date().addingTimeInterval(30)
        task.status = .completed
        context.insert(run)

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Create the page")
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        var staleState = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(staleState.artifacts.isEmpty)
        #expect(staleState.changedFiles.isEmpty)
        #expect(staleState.verification.artifactStatus == "none recorded")

        let indexPath = (folder as NSString).appendingPathComponent("index.html")
        try "<!doctype html><html><body>Late artifact</body></html>".write(
            toFile: indexPath,
            atomically: true,
            encoding: .utf8
        )

        staleState = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(staleState.artifacts.isEmpty)
        TaskContextStateManager.refresh(task: task)

        let repairedState = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(repairedState.filesChanged.contains(indexPath))
        #expect(repairedState.changedFiles.contains { $0.path == indexPath })
        #expect(repairedState.artifacts.contains { $0.path == indexPath && $0.type == "html" })
        #expect(task.artifacts.isEmpty)
        #expect(repairedState.verification.artifactStatus == "1 current")

        TaskContextStateManager.refresh(task: task)
        #expect(task.artifacts.isEmpty)
    }

    @Test("context capsule surfaces deliverable verification evidence")
    func contextCapsuleSurfacesDeliverableVerificationEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Deliverable Evidence", primaryPath: root)
        let task = AgentTask(
            title: "Create HTML",
            goal: "create a web page with html and javascript",
            workspace: workspace
        )
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.completedAt = Date()
        task.status = .completed
        context.insert(run)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let indexPath = (folder as NSString).appendingPathComponent("index.html")
        try """
        <!doctype html><html><body><script>function ok() { return true; }</script></body></html>
        """.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = await TaskDeliverableVerificationService.evaluate(
            task: task,
            run: run,
            environment: TaskDeliverableVerificationEnvironment(checkJavaScriptSyntax: { _, _ in .passed })
        )
        context.insert(TaskEvent(
            task: task,
            type: TaskDeliverableVerificationEventTypes.passed,
            payload: TaskDeliverableVerificationService.encode(result),
            run: run
        ))

        TaskContextStateManager.refresh(task: task)

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.verification.status == "passed")
        #expect(state.verification.strategy == "deliverable_verification")
        #expect(state.verification.deliverableLevel == "syntax_verified")
        #expect(state.verification.deliverableChecks.contains {
            $0.id.hasPrefix("javascript.syntax") && $0.status == "passed"
        })
        #expect(TaskContextStateManager.promptContext(for: task)?.contains("Deliverable quality: syntax_verified") == true)
    }

    @Test("context capsule is primary prompt context before raw transcript")
    func contextCapsulePrecedesRawTranscript() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Prompt Ordering", primaryPath: root)
        let task = AgentTask(title: "Prompt Ordering", goal: "Current objective from task should be primary", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Old transcript says: use provider-native session memory as the main source."
        run.completedAt = Date()
        task.status = .completed
        context.insert(run)
        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: "Try the old approach"
        )

        task.goal = "Current objective from edited task must stay primary"
        TaskContextStateManager.refresh(task: task)

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        let capsuleRange = try #require(prompt.range(of: "Context Capsule v2:"))
        let transcriptRange = try #require(prompt.range(of: "Recent conversation transcript"))
        #expect(capsuleRange.lowerBound < transcriptRange.lowerBound)
        #expect(prompt.contains("Current objective: Current objective from edited task must stay primary"))
        #expect(prompt.contains("Old transcript says: use provider-native session memory"))
    }

    @Test("prompt generation creates a fresh context capsule when none exists")
    func promptGenerationCreatesFreshContextCapsule() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Fresh Prompt", primaryPath: root)
        let task = AgentTask(title: "Fresh Prompt", goal: "Create state at prompt boundary", workspace: workspace)
        task.constraints = ["Prompt must include canonical compact state"]
        context.insert(workspace)
        context.insert(task)

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))

        #expect(prompt.contains("Context Capsule v2:"))
        #expect(prompt.contains("Current objective: Create state at prompt boundary"))
        #expect(prompt.contains("Prompt must include canonical compact state"))
        #expect(!prompt.contains("Generated files in task folder"))
        #expect(state.schemaVersion == 2)
        #expect(state.objective.currentObjective == "Create state at prompt boundary")
    }

    @Test("prompt generation refreshes stale context capsule before provider handoff")
    func promptGenerationRefreshesStaleContextCapsule() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Stale Prompt", primaryPath: root)
        let task = AgentTask(title: "Stale Prompt", goal: "Old objective", workspace: workspace)
        task.constraints = ["Old constraint"]
        context.insert(workspace)
        context.insert(task)

        TaskContextStateManager.refresh(task: task)
        task.goal = "New objective from edited task"
        task.constraints = ["New constraint"]
        task.acceptanceCriteria = ["New acceptance criterion"]
        task.testCommand = "swift test --filter NewCapsuleTests"

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))

        #expect(prompt.contains("Current objective: New objective from edited task"))
        #expect(prompt.contains("New constraint"))
        #expect(prompt.contains("New acceptance criterion"))
        #expect(prompt.contains("Test command: swift test --filter NewCapsuleTests"))
        #expect(state.startingRequest == "Old objective")
        #expect(state.objective.currentObjective == "New objective from edited task")
        #expect(state.constraints.map(\.text) == ["New constraint"])
        #expect(state.acceptanceCriteria.map(\.text) == ["New acceptance criterion"])
        #expect(state.testCommand == "swift test --filter NewCapsuleTests")
    }

    @Test("context capsule migrates v1 state without dropping prompt context")
    func contextCapsuleMigratesV1State() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Migration", primaryPath: root)
        let task = AgentTask(title: "Migration", goal: "Refresh migrated capsule", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let legacyJSON = """
        {
          "approvedGoal": "Ship the v1 capsule safely",
          "blockers": ["Need migration coverage"],
          "candidateGoals": [],
          "currentObjective": "Keep old context available",
          "decisions": ["Use current_state as canonical compact memory"],
          "filesChanged": ["Astra/Services/Persistence/TaskContextStateManager.swift"],
          "mode": "planning",
          "nextLikelyAction": "Continue migration",
          "openQuestions": [],
          "rejectedOptions": [],
          "schemaVersion": 1,
          "startingRequest": "Make current_state canonical",
          "turns": [
            {
              "ask": "What changes?",
              "blockers": [],
              "completedAt": "2026-05-30T00:00:00.000Z",
              "filesChanged": ["Astra/Services/Persistence/TaskContextStateManager.swift"],
              "outputFile": "outputs/turn_001.md",
              "runStatus": "completed",
              "summary": "Legacy turn survives migration.",
              "turn": 1
            }
          ],
          "updatedAt": "2026-05-30T00:00:00.000Z"
        }
        """
        try legacyJSON.write(
            toFile: (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName),
            atomically: true,
            encoding: .utf8
        )

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Context Capsule v2:"))
        #expect(prompt.contains("Current objective: Ship the v1 capsule safely"))
        #expect(prompt.contains("Use current_state as canonical compact memory"))
        #expect(prompt.contains("Legacy turn survives migration."))
        #expect(!prompt.contains("Generated files in task folder"))

        TaskContextStateManager.refresh(task: task)
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.schemaVersion == 2)
        #expect(state.turns.map(\.summary).contains("Legacy turn survives migration."))
        #expect(state.decisionFacts.contains { $0.text == "Use current_state as canonical compact memory" })
        #expect(state.verification.strategy == ValidationStrategy.manual.rawValue)
    }

    @Test("follow-up prompts include thread intent and history lookup rule")
    func followUpPromptIncludesThreadIntent() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Prompt", primaryPath: root)
        let task = AgentTask(title: "Context prompt", goal: "Explore better follow-up memory", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Current-state checkpoints are simpler than a search index for the first iteration."
        run.completedAt = Date()
        context.insert(run)
        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: "What should we build first?"
        )

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "What did we decide about vectors?",
            task: task
        )
        #expect(prompt.contains("Thread Intent:"))
        #expect(prompt.contains("Current-state checkpoints are simpler"))
        #expect(prompt.contains(TaskContextStateManager.jsonFileName))
        #expect(prompt.contains("History Lookup Rule:"))
        #expect(prompt.contains("Goal: Explore better follow-up memory"))
    }

    @Test("prompt diagnostics report state and history sizes")
    func promptDiagnosticsReportStatePresence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Diagnostics", primaryPath: root)
        let task = AgentTask(title: "Diagnostics", goal: "Measure prompt context", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Diagnostics should include current-state size."
        run.completedAt = Date()
        context.insert(run)
        AgentRuntimeRunPersistence.recordSessionTurn(task: task, run: run, message: "measure")

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "continue", task: task)
        let fields = TaskContextStateManager.promptDiagnosticsFields(task: task, prompt: prompt, phase: "resume")
        #expect(fields["has_context_capsule"] == "true")
        #expect(fields["has_thread_intent"] == "true")
        #expect(Int(fields["state_json_chars"] ?? "0", radix: 10) ?? 0 > 0)
        #expect(Int(fields["session_history_chars"] ?? "0", radix: 10) ?? 0 > 0)
        #expect(fields["output_file_count"] == "1")
        #expect(Int(fields["output_latest_chars"] ?? "0", radix: 10) ?? 0 > 0)
    }

    @Test("oversized capsule truncates the body but preserves the recovery pointer")
    func oversizedCapsulePreservesRecoveryPointer() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Truncate", primaryPath: root)
        let task = AgentTask(title: "Big capsule", goal: "Stress the prompt budget", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()

        func longFacts(_ tag: String, _ count: Int) -> [TaskContextState.ContextFact] {
            (0..<count).map { index in
                TaskContextState.ContextFact(
                    text: String(repeating: "\(tag)\(index) ", count: 60),
                    sourcePointers: [],
                    confidence: "derived"
                )
            }
        }

        // Fill multiple capped sections so the rendered body far exceeds the 6_000-char
        // block budget and forces the truncation path.
        var state = minimalState()
        state.constraints = longFacts("constraint", 6)
        state.acceptanceCriteria = longFacts("criterion", 6)
        state.standingInstructions = longFacts("standing", 8)
        state.decisionFacts = longFacts("decision", 6)
        state.changedFiles = (0..<8).map { index in
            TaskContextState.ChangedFile(
                path: "/repo/" + String(repeating: "segment\(index)/", count: 30) + "file.swift",
                changeType: "edit",
                sourcePointers: []
            )
        }
        #expect(TaskContextStateManager.saveState(state, taskFolder: folder).didSave)

        let prompt = try #require(TaskContextStateManager.promptContext(for: task))
        #expect(prompt.contains("... (thread intent truncated)"))   // truncation path was exercised
        #expect(prompt.contains("- Canonical state file: \(folder)/\(TaskContextStateManager.jsonFileName)"))
        // The recovery tail is the literal end of the block — proof it was not the casualty.
        #expect(prompt.hasSuffix("exact prior wording."))
    }

    @Test("decode failure quarantines the corrupt state file instead of silently discarding it")
    func decodeFailureQuarantinesCorruptState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Recover", primaryPath: root)
        let task = AgentTask(title: "Corrupt", goal: "Survive a corrupt capsule", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let jsonPath = (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)
        try "{ not valid json".write(toFile: jsonPath, atomically: true, encoding: .utf8)

        // refresh() recomputes derived state; it must NOT overwrite the unreadable file
        // in place — the original bytes are preserved under a quarantine name.
        TaskContextStateManager.refresh(task: task)

        let fileManager = FileManager.default
        let quarantined = try fileManager.contentsOfDirectory(atPath: folder)
            .filter { $0.hasPrefix("current_state.corrupt-") && $0.hasSuffix(".json") }
        #expect(quarantined.count == 1)
        let quarantinePath = (folder as NSString).appendingPathComponent(try #require(quarantined.first))
        #expect(try String(contentsOfFile: quarantinePath, encoding: .utf8) == "{ not valid json")
        // The task recovered to a fresh, valid capsule rather than staying blocked.
        #expect(TaskContextStateManager.loadResult(taskFolder: folder).status == .loadedCurrent)
    }

    @Test("a newer-schema capsule is backed up and its content is reused instead of discarded")
    func newerSchemaCapsuleIsPreservedAsDegradedRead() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Future", primaryPath: root)
        let task = AgentTask(title: "Newer", goal: "Open a capsule from a newer build", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let jsonPath = (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)

        // Structurally a current capsule, but stamped with a schema this build predates.
        var future = minimalState()
        future.schemaVersion = 99
        future.currentObjective = "Objective written by a newer build"
        try JSONEncoder().encode(future).write(to: URL(fileURLWithPath: jsonPath))

        // A plain load rejects the unknown version outright...
        #expect(TaskContextStateManager.loadResult(taskFolder: folder).status == .unsupportedSchema)

        // ...but recovery backs up the original and reuses its readable content.
        let recovered = try #require(TaskContextStateRecovery.recoverState(taskFolder: folder, taskID: task.id))
        #expect(recovered.currentObjective == "Objective written by a newer build") // not blanked
        #expect(recovered.schemaVersion == TaskContextStateManager.schemaVersion)    // re-labeled to current
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasPrefix("current_state.v99-backup") }
        #expect(backups.count == 1)
        // A second recovery does not pile up duplicate backups.
        _ = TaskContextStateRecovery.recoverState(taskFolder: folder, taskID: task.id)
        let backupsAfter = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasPrefix("current_state.v99-backup") }
        #expect(backupsAfter.count == 1)
    }

    @Test("verification classification stays coupled to the producer's outcome markers")
    func verificationClassificationFollowsOutcomeMarkers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verify", primaryPath: root)
        let task = AgentTask(title: "Classify", goal: "Classify validation outcomes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        // Build the payload exactly as AgentRuntimeWorker does — from the shared marker.
        // If producer and consumer ever drift, this classification flips and the test fails.
        let passEvent = TaskEvent(task: task, type: "task.completed",
                                  payload: "\(ValidationOutcomeMarker.testsPassed.rawValue). 42 examples")
        passEvent.timestamp = Date(timeIntervalSince1970: 10)
        context.insert(passEvent)
        TaskContextStateManager.refresh(task: task)
        var state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.verification.status == "passed")
        #expect(state.verification.completionVerified)

        // A later AI-check error must reclassify to "error" via the aiCheckError marker.
        let errorEvent = TaskEvent(task: task, type: "error",
                                   payload: "\(ValidationOutcomeMarker.aiCheckError.rawValue): model timed out. Needs manual review.")
        errorEvent.timestamp = Date(timeIntervalSince1970: 20)
        context.insert(errorEvent)
        TaskContextStateManager.refresh(task: task)
        state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.verification.status == "error")
        #expect(!state.verification.completionVerified)
    }

    @Test("prompt block surfaces every populated section within budget and renders deterministically")
    func promptBlockCoversSectionsWithinBudget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Snapshot", primaryPath: root)
        let task = AgentTask(title: "Rich", goal: "Render a fully-populated capsule", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        #expect(TaskContextStateManager.saveState(CapsuleSnapshotTests.richState(), taskFolder: folder).didSave)

        let prompt = try #require(TaskContextStateManager.promptContext(for: task))

        // Every populated section must reach the model-facing block.
        for marker in [
            "Context Capsule v2:", "Current objective:", "Approved goal:", "Constraints:",
            "Acceptance criteria:", "Standing user instructions", "Validation contract: passed",
            "Decisions:", "Blockers:", "Files changed:", "Verification: passed", "Artifacts:",
            "Latest handoff:", "Corrective work:", "Next likely action:", "Recent state turns:"
        ] {
            #expect(prompt.contains(marker), "prompt block missing section: \(marker)")
        }
        #expect(prompt.count <= 6_000) // mirrors TaskContextStateManager.promptBlockCharacterLimit
        #expect(prompt.contains("- Canonical state file: \(folder)/\(TaskContextStateManager.jsonFileName)"))
        // Deterministic for a stable state + budget (prompt-assembly invariant).
        #expect(TaskContextStateManager.promptContext(for: task) == prompt)
    }

    @Test("repeated quarantines in the same second do not overwrite each other")
    func repeatedQuarantinesArePreserved() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Quarantine", primaryPath: root)
        let task = AgentTask(title: "Repeat", goal: "Survive repeated corruption", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let jsonPath = (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)

        try "{ corrupt one".write(toFile: jsonPath, atomically: true, encoding: .utf8)
        TaskContextStateManager.refresh(task: task) // quarantine #1, then fresh save
        try "{ corrupt two".write(toFile: jsonPath, atomically: true, encoding: .utf8)
        TaskContextStateManager.refresh(task: task) // quarantine #2, same wall-clock second

        let quarantined = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasPrefix("current_state.corrupt-") && $0.hasSuffix(".json") }
        #expect(quarantined.count == 2) // neither overwrote the other
        var preserved: Set<String> = []
        for name in quarantined {
            preserved.insert(try String(contentsOfFile: (folder as NSString).appendingPathComponent(name), encoding: .utf8))
        }
        #expect(preserved == ["{ corrupt one", "{ corrupt two"])
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-context-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func minimalState(schemaVersion: Int = 2) -> TaskContextState {
        TaskContextState(
            schemaVersion: schemaVersion,
            mode: .exploration,
            startingRequest: "Start",
            currentObjective: "Current",
            objective: TaskContextState.Objective(
                startingRequest: "Start",
                currentObjective: "Current",
                approvedGoal: nil,
                sourcePointers: []
            ),
            constraints: [],
            acceptanceCriteria: [],
            testCommand: nil,
            decisions: ["Use structured diagnostics"],
            decisionFacts: [],
            rejectedOptions: [],
            openQuestions: [],
            candidateGoals: [],
            approvedGoal: nil,
            blockers: [],
            blockerFacts: [],
            filesChanged: [],
            changedFiles: [],
            artifacts: [],
            verification: TaskContextState.Verification(
                status: "not_verified",
                strategy: "manual",
                command: nil,
                summary: "No validation has run.",
                evidence: [],
                updatedAt: nil
            ),
            validationContract: nil,
            latestHandoff: nil,
            correctiveWork: nil,
            sourcePointers: [],
            nextLikelyAction: nil,
            objectiveDivergenceNote: nil,
            standingInstructions: nil,
            turns: [],
            updatedAt: "2026-06-05T00:00:00Z"
        )
    }
}
