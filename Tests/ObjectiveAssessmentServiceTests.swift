import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeObjectiveAssessmentServiceContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Objective assessment service")
@MainActor
struct ObjectiveAssessmentServiceTests {
    // MARK: - Success path

    @Test("valid JSON verdict is persisted into the capsule")
    func validJSONPersistsVerdict() async throws {
        let fixture = try makeReadyToAssessFixture(named: "valid-json")
        defer { fixture.cleanup() }

        var callCount = 0
        await ObjectiveAssessmentService.assessIfNeeded(
            task: fixture.task,
            utilityRuntime: fixture.utilityRuntime
        ) { _, _, _ in
            callCount += 1
            return AgentUtilityRunResult(
                exitCode: 0,
                output: #"{"verdict":"superseded","currentObjective":"Actually fix the CSV export instead"}"#,
                error: ""
            )
        }

        #expect(callCount == 1)
        let state = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(state.objectiveAssessment?.verdict == "superseded")
        #expect(state.objectiveAssessment?.currentObjective == "Actually fix the CSV export instead")
        #expect(state.objectiveAssessment?.assessedAtTurn == fixture.turnCountBeforeAssessment)
    }

    // MARK: - Fail-safe: malformed JSON

    @Test("malformed JSON leaves prior state unchanged")
    func malformedJSONIsNoOp() async throws {
        let fixture = try makeReadyToAssessFixture(named: "malformed-json")
        defer { fixture.cleanup() }

        let priorState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(priorState.objectiveAssessment == nil)

        await ObjectiveAssessmentService.assessIfNeeded(
            task: fixture.task,
            utilityRuntime: fixture.utilityRuntime
        ) { _, _, _ in
            AgentUtilityRunResult(exitCode: 0, output: "not json at all", error: "")
        }

        let afterState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(afterState.objectiveAssessment == nil)
        #expect(afterState == priorState)
    }

    @Test("JSON missing the verdict key leaves prior state unchanged")
    func missingVerdictKeyIsNoOp() async throws {
        let fixture = try makeReadyToAssessFixture(named: "missing-verdict")
        defer { fixture.cleanup() }

        let priorState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))

        await ObjectiveAssessmentService.assessIfNeeded(
            task: fixture.task,
            utilityRuntime: fixture.utilityRuntime
        ) { _, _, _ in
            AgentUtilityRunResult(exitCode: 0, output: #"{"currentObjective":"Something else"}"#, error: "")
        }

        let afterState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(afterState.objectiveAssessment == nil)
        #expect(afterState == priorState)
    }

    @Test("superseded verdict without a currentObjective leaves prior state unchanged")
    func supersededWithoutObjectiveIsNoOp() async throws {
        let fixture = try makeReadyToAssessFixture(named: "superseded-no-objective")
        defer { fixture.cleanup() }

        let priorState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))

        await ObjectiveAssessmentService.assessIfNeeded(
            task: fixture.task,
            utilityRuntime: fixture.utilityRuntime
        ) { _, _, _ in
            AgentUtilityRunResult(exitCode: 0, output: #"{"verdict":"superseded"}"#, error: "")
        }

        let afterState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(afterState.objectiveAssessment == nil)
        #expect(afterState == priorState)
    }

    // MARK: - Fail-safe: provider error / timeout

    @Test("provider error (non-zero exit) leaves capsule state unchanged")
    func providerErrorIsNoOp() async throws {
        let fixture = try makeReadyToAssessFixture(named: "provider-error")
        defer { fixture.cleanup() }

        let priorState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))

        await ObjectiveAssessmentService.assessIfNeeded(
            task: fixture.task,
            utilityRuntime: fixture.utilityRuntime
        ) { _, _, _ in
            AgentUtilityRunResult(exitCode: -1, output: "", error: "timed out")
        }

        let afterState = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(afterState.objectiveAssessment == nil)
        #expect(afterState == priorState)
    }

    // MARK: - Cost control: trigger predicate gates invocation

    @Test("trigger predicate false means the provider is never invoked")
    func triggerFalseNeverInvokesProvider() async throws {
        // Only one turn recorded -- turnCount stays well below the trigger's
        // turnThreshold, so shouldAssess must return false and the (expensive)
        // provider call must never happen.
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeObjectiveAssessmentServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Trigger Gate", primaryPath: root)
        let task = AgentTask(title: "Single turn", goal: "Ship the release notes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "done"
        run.completedAt = Date()
        context.insert(run)
        TaskContextStateManager.recordTurn(task: task, run: run, message: "Ship the release notes")

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        var callCount = 0
        await ObjectiveAssessmentService.assessIfNeeded(
            task: task,
            utilityRuntime: AgentUtilityRuntimeConfiguration(runtime: .claudeCode, model: "claude-haiku-4-5-20251001")
        ) { _, _, _ in
            callCount += 1
            return AgentUtilityRunResult(exitCode: 0, output: #"{"verdict":"original_active"}"#, error: "")
        }

        #expect(callCount == 0)
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.objectiveAssessment == nil)
    }

    // MARK: - Settings toggle off means the service is never invoked

    @Test("settings toggle off means recordSessionTurn never triggers assessment")
    func settingsToggleOffNeverInvokesService() async throws {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(false, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let root = try temporaryRoot(name: "toggle-off")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeObjectiveAssessmentServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Toggle Off", primaryPath: root)
        let task = AgentTask(title: "Toggle off", goal: "Ship the release notes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let firstMessage = TaskEvent(task: task, type: "user.message", payload: "Ship the release notes")
        firstMessage.timestamp = Date(timeIntervalSince1970: 0)
        context.insert(firstMessage)

        // Enough turns + a substantive later message to satisfy the trigger
        // predicate on its own -- if the toggle were the only thing gating
        // invocation, this sequence would normally fire an assessment.
        for index in 0..<6 {
            let run = TaskRun(task: task)
            run.status = .completed
            run.stopReason = "completed"
            run.output = "progress \(index)"
            run.completedAt = Date()
            context.insert(run)
            let message = index == 5
                ? "Actually, let's scrap that and rework the CSV exporter instead"
                : "Please also double-check the changelog formatting"
            let userMessageEvent = TaskEvent(task: task, type: "user.message", payload: message)
            userMessageEvent.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(userMessageEvent)
            AgentRuntimeRunPersistence.recordSessionTurn(task: task, run: run, message: message)
        }

        // recordSessionTurn only schedules an unawaited background Task when
        // the toggle is on; give any (incorrectly) scheduled work a chance to
        // run before asserting it never touched the capsule.
        try await Task.sleep(nanoseconds: 200_000_000)

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.objectiveAssessment == nil)
    }

    // MARK: - Settings toggle off clears a previously-persisted assessment

    @Test("settings toggle off clears a stale persisted assessment on the next turn")
    func settingsToggleOffClearsStaleAssessment() throws {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(false, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let root = try temporaryRoot(name: "toggle-off-clears-stale")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeObjectiveAssessmentServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Toggle Off Clears Stale", primaryPath: root)
        let task = AgentTask(title: "Toggle off clears stale", goal: "Ship the release notes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        TaskContextStateManager.refresh(task: task)
        var state = try #require(TaskContextStateManager.load(taskFolder: folder))
        // Simulate a verdict persisted from an earlier turn while the setting
        // was still enabled.
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "Rework the CSV exporter instead",
            assessedAtTurn: 4,
            inputHash: "hash-toggle-off-clears-stale"
        )
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "done"
        run.completedAt = Date()
        context.insert(run)

        // The setting is off, so recordSessionTurn must not merely skip
        // scheduling a new Tier 2 run -- it must also drop the stale verdict
        // already on disk from before the user opted out.
        AgentRuntimeRunPersistence.recordSessionTurn(task: task, run: run, message: "Thanks, one more thing")

        let reloaded = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(reloaded.objectiveAssessment == nil)
    }

    // MARK: - Race safety: out-of-order writes don't clobber a newer verdict

    @Test("a slower, earlier-turn assessment does not clobber a newer already-persisted verdict")
    func staleOutOfOrderAssessmentDoesNotOverwriteNewer() async throws {
        let fixture = try makeReadyToAssessFixture(named: "race-guard")
        defer { fixture.cleanup() }

        // Simulate a faster, LATER-turn assessment that already landed while
        // this (earlier-turn) call was still in flight (adversarial finding:
        // two turns can each schedule an unawaited assessment before either
        // resolves).
        var state = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "The genuinely newer objective",
            assessedAtTurn: fixture.turnCountBeforeAssessment + 50,
            inputHash: "hash-from-a-later-turn"
        )
        TaskContextStateManager.saveState(state, taskFolder: fixture.folder, taskID: fixture.task.id)

        await ObjectiveAssessmentService.assessIfNeeded(
            task: fixture.task,
            utilityRuntime: fixture.utilityRuntime
        ) { _, _, _ in
            AgentUtilityRunResult(
                exitCode: 0,
                output: #"{"verdict":"superseded","currentObjective":"A stale, out-of-order objective"}"#,
                error: ""
            )
        }

        let after = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        // The newer, already-persisted verdict must survive untouched.
        #expect(after.objectiveAssessment?.currentObjective == "The genuinely newer objective")
        #expect(after.objectiveAssessment?.assessedAtTurn == fixture.turnCountBeforeAssessment + 50)
    }

    // MARK: - The sole early follow-up must not be dropped as a goal restatement

    @Test("the sole early follow-up is not dropped as if it were the original goal restated")
    func firstGenuineFollowUpIsNotDroppedByPosition() async throws {
        // In production, an initial provider run logs `task.started` (not
        // `user.message`) for the goal, so the FIRST `user.message` event is
        // often the user's first genuine follow-up. Regression guard: this
        // must not be treated as "the original goal restated" and silently
        // dropped just because it happens to be first (adversarial finding).
        let root = try temporaryRoot(name: "first-followup-not-dropped")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeObjectiveAssessmentServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "First Follow-up", primaryPath: root)
        let task = AgentTask(title: "First follow-up", goal: "Ship the release notes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        // No "restates the goal" event at all -- mirrors the direct-execution
        // task-creation flow, where the goal is never logged as a
        // `user.message`.
        for index in 0..<6 {
            let run = TaskRun(task: task)
            run.status = .completed
            run.stopReason = "completed"
            run.output = "progress \(index)"
            run.completedAt = Date()
            context.insert(run)
            TaskContextStateManager.recordTurn(task: task, run: run, message: "progress \(index)")
        }
        // The ONLY user.message event in the whole thread -- a genuine,
        // distinct follow-up, not a restatement of the goal.
        let onlyFollowUp = TaskEvent(
            task: task,
            type: "user.message",
            payload: "Actually, let's scrap that and rework the CSV exporter instead"
        )
        onlyFollowUp.timestamp = Date(timeIntervalSince1970: 100)
        context.insert(onlyFollowUp)
        try context.save()

        var callCount = 0
        await ObjectiveAssessmentService.assessIfNeeded(
            task: task,
            utilityRuntime: AgentUtilityRuntimeConfiguration(runtime: .claudeCode, model: "claude-haiku-4-5-20251001")
        ) { _, _, _ in
            callCount += 1
            return AgentUtilityRunResult(exitCode: 0, output: #"{"verdict":"original_active"}"#, error: "")
        }

        #expect(callCount == 1)
    }

    // MARK: - Default utility model must not fall back to the task model

    @Test("resolves the utility model default when Settings has never set validationModel")
    func defaultUtilityModelFallsBackToHaikuNotTaskModel() async throws {
        let fixture = try makeReadyToAssessFixture(named: "default-utility-model")
        defer { fixture.cleanup() }

        let defaults = UserDefaults.standard
        let key = AppStorageKeys.validationModel
        let original = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        var observedModel: String?
        // No `utilityRuntime:` override -- forces resolution from
        // `UserDefaults` (adversarial finding: on a fresh install, before
        // Settings has ever been opened, this must not fall back to the
        // larger, general task-execution model).
        await ObjectiveAssessmentService.assessIfNeeded(task: fixture.task) { _, _, configuration in
            observedModel = configuration.model
            return AgentUtilityRunResult(exitCode: 0, output: #"{"verdict":"original_active"}"#, error: "")
        }

        #expect(observedModel != nil)
        #expect(observedModel != TaskExecutionDefaults.model)
        #expect(observedModel == "claude-haiku-4-5-20251001")
    }

    // MARK: - Fixture

    private struct AssessmentFixture {
        var task: AgentTask
        var folder: String
        var root: String
        var utilityRuntime: AgentUtilityRuntimeConfiguration
        var turnCountBeforeAssessment: Int

        func cleanup() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    /// Builds a task with enough recorded turns and a substantive later user
    /// message so `ObjectiveAssessmentTrigger.shouldAssess` returns true.
    private func makeReadyToAssessFixture(named name: String) throws -> AssessmentFixture {
        let root = try temporaryRoot(name: name)
        let container = try makeObjectiveAssessmentServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Assess \(name)", primaryPath: root)
        let task = AgentTask(title: "Assess \(name)", goal: "Ship the release notes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        // First turn carries the original goal as the first "user message"
        // (excluded from the "later substantive message" signal by design).
        let firstMessage = TaskEvent(task: task, type: "user.message", payload: "Ship the release notes")
        firstMessage.timestamp = Date(timeIntervalSince1970: 0)
        context.insert(firstMessage)

        for index in 0..<6 {
            let run = TaskRun(task: task)
            run.status = .completed
            run.stopReason = "completed"
            run.output = "progress \(index)"
            run.completedAt = Date()
            context.insert(run)
            let message = index == 5
                ? "Actually, let's scrap that and rework the CSV exporter instead"
                : "Please also double-check the changelog formatting"
            let userMessageEvent = TaskEvent(task: task, type: "user.message", payload: message)
            userMessageEvent.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(userMessageEvent)
            TaskContextStateManager.recordTurn(task: task, run: run, message: message)
        }

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))

        return AssessmentFixture(
            task: task,
            folder: folder,
            root: root,
            utilityRuntime: AgentUtilityRuntimeConfiguration(runtime: .claudeCode, model: "claude-haiku-4-5-20251001"),
            turnCountBeforeAssessment: state.turns.count
        )
    }

    private func temporaryRoot(name: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-objective-assessment-service-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func temporaryRoot() throws -> String {
        try temporaryRoot(name: "gate")
    }
}
