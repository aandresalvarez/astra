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
            path: "\(root)/Astra/Services/AgentPromptBuilder.swift",
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
        #expect(state.verification.summary.contains("Tests failed"))
        #expect(state.verification.evidence.contains { $0.kind == "event" && $0.id == validationEvent.id.uuidString })
        #expect(state.blockerFacts.contains { $0.sourcePointers.contains { $0.id == validationEvent.id.uuidString } })

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Fix the validation failure", task: task)
        #expect(prompt.contains("Verification: failed via run_tests"))
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
        #expect(state.verification.evidence.contains { $0.kind == "event" && $0.id == validationEvent.id.uuidString })
        #expect(state.nextLikelyAction == "Review the result, approve it, or ask a follow-up.")
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
          "filesChanged": ["Astra/Services/TaskContextStateManager.swift"],
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
              "filesChanged": ["Astra/Services/TaskContextStateManager.swift"],
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

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-context-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
