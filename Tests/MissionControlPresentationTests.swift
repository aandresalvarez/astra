import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private func makeMissionControlContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Mission Control presentation")
@MainActor
struct MissionControlPresentationTests {
    @Test("mission control snapshot loads source state and finished verification request")
    func missionControlSnapshotLoadsSourceStateAndFinishedVerificationRequest() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let task = makeFinishedSnapshotTask(root: root, context: context)

        TaskContextStateManager.refresh(task: task)

        let source = TaskMissionControlSnapshot.Source.load(
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
            taskID: task.id
        )
        let snapshot = TaskMissionControlSnapshot.build(task: task, planState: .empty, source: source)

        // The load resolves the same folder the view used to `stat` per pass.
        #expect(source.taskFolder == TaskWorkspaceAccess(task: task).taskFolder)
        #expect(source.state != nil)
        #expect(snapshot.taskID == task.id)
        #expect(snapshot.taskFolder == source.taskFolder)
        #expect(snapshot.presentation?.objective == "Summarize mission snapshot")

        let request = TaskMissionControlSnapshot.verificationLoadRequest(
            task: task,
            taskFolder: snapshot.taskFolder,
            isFinished: true
        )
        #expect(request?.taskID == task.id)
        #expect(request?.taskStatus == .completed)
        #expect(request?.taskUpdatedAt == task.updatedAt)
        #expect(request?.taskFolder == snapshot.taskFolder)
        #expect(TaskMissionControlSnapshot.verificationLoadRequest(
            task: task,
            taskFolder: snapshot.taskFolder,
            isFinished: false
        ) == nil)
        // Before the first rebuild lands the cache has no folder to offer.
        #expect(TaskMissionControlSnapshot.verificationLoadRequest(
            task: task,
            taskFolder: TaskMissionControlSnapshot.empty.taskFolder,
            isFinished: true
        ) == nil)
    }

    /// The mission-control cache is keyed on model scalars and cannot see
    /// `current_state.json`. This signal is how a turn recorded at the end of a
    /// run — or any refresh that rewrites the file — reaches the dock.
    @Test("recording a turn announces the state save that invalidates mission control")
    func recordingATurnAnnouncesTheStateSave() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let task = makeFinishedSnapshotTask(root: root, context: context)
        let run = try #require(task.runs.first)
        let taskID = task.id
        var saves = 0
        let token = NotificationCenter.default.addObserver(
            forName: .taskContextStateDidSave,
            object: nil,
            queue: nil
        ) { notification in
            guard (notification.object as? TaskContextStateSave)?.taskID == taskID else { return }
            saves += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Summarize the mission")
        #expect(saves == 1)

        // Once settled, a refresh with nothing new skips the write, and the
        // signal with it; otherwise every task open would reload the dock.
        TaskContextStateManager.refresh(task: task)
        let settled = saves
        TaskContextStateManager.refresh(task: task)
        #expect(saves == settled)

        // A failed write leaves the previous file in place: nothing to reload.
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        let failed = TaskContextStateManager.saveState(state, taskFolder: "/dev/null/unwritable", taskID: taskID)
        #expect(!failed.didSave)
        #expect(saves == settled)

        // The Markdown twin is written second, so failing it arrives with the
        // JSON already replaced: `didSave` is false, but the cache is stale.
        let markdownPath = (folder as NSString).appendingPathComponent(TaskContextStateManager.markdownFileName)
        try FileManager.default.removeItem(atPath: markdownPath)
        try FileManager.default.createDirectory(atPath: markdownPath, withIntermediateDirectories: false)
        let markdownFailed = TaskContextStateManager.saveState(state, taskFolder: folder, taskID: taskID)
        #expect(markdownFailed.status == .writeMarkdownFailed)
        #expect(saves == settled + 1)
    }

    /// The presentation asks only whether a task has events, when it has no
    /// state file to go on. Keying the exact count rebuilt the snapshot, and
    /// reread the file, on every event a streaming run records.
    @Test("mission control key tracks whether events exist, not how many")
    func missionControlKeyTracksEventPresenceNotCount() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let task = makeFinishedSnapshotTask(root: root, context: context)
        let first = TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: "First")
        let second = TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: "Second")
        context.insert(first)
        context.insert(second)

        func key(_ events: [TaskEvent]) -> TaskMissionControlSnapshot.Inputs {
            let thread = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: events, runs: task.runs)
            return TaskMissionControlSnapshot.Inputs(task: task, thread: thread, planState: .empty, stateRevision: 0)
        }

        #expect(key([first]) == key([first, second]))
        #expect(key([]) != key([first]))
    }

    /// `body` re-runs on every keystroke in the composer, and `.task(id:)`
    /// rebuilds the snapshot only when its key changes. So the key has to
    /// compare equal across passes that moved nothing it names, without
    /// reading the file to find that out, and the save signal has to be what
    /// moves it when only the file changed.
    @Test("mission control key holds across unrelated passes and moves on a state save")
    func missionControlKeyHoldsAcrossUnrelatedPassesAndMovesOnStateSave() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let task = makeFinishedSnapshotTask(root: root, context: context)
        TaskContextStateManager.refresh(task: task)
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskID = task.id
        // Stands in for `TaskContextStateSaveObserver`, which does this for the view.
        var stateRevision = 0
        let token = NotificationCenter.default.addObserver(
            forName: .taskContextStateDidSave,
            object: nil,
            queue: nil
        ) { notification in
            guard (notification.object as? TaskContextStateSave)?.taskID == taskID else { return }
            stateRevision += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let key = TaskMissionControlSnapshot.Inputs(task: task, thread: nil, planState: .empty, stateRevision: stateRevision)
        let source = await Task.detached {
            TaskMissionControlSnapshot.Source.load(workspacePath: workspacePath, taskID: taskID)
        }.value
        let snapshot = TaskMissionControlSnapshot.build(task: task, planState: .empty, source: source)
        #expect(snapshot.presentation?.nextAction == "Review the result, approve it, or ask a follow-up.")

        // Only the file moves; the model is untouched.
        var edited = try #require(source.state)
        edited.nextLikelyAction = "Ship the reviewed draft."
        #expect(TaskContextStateManager.saveState(edited, taskFolder: source.taskFolder, taskID: taskID).didSave)

        // A pass that changed nothing the key names — a keystroke — compares
        // equal even though the file on disk no longer matches the cache.
        #expect(TaskMissionControlSnapshot.Inputs(task: task, thread: nil, planState: .empty, stateRevision: 0) == key)
        // The save is what moves it...
        #expect(stateRevision == 1)
        #expect(TaskMissionControlSnapshot.Inputs(task: task, thread: nil, planState: .empty, stateRevision: stateRevision) != key)
        // ...and the rebuild that follows reads the new file.
        let reloaded = await Task.detached {
            TaskMissionControlSnapshot.Source.load(workspacePath: workspacePath, taskID: taskID)
        }.value
        let rebuilt = TaskMissionControlSnapshot.build(task: task, planState: .empty, source: reloaded)
        #expect(rebuilt.presentation?.nextAction == "Ship the reviewed draft.")

        // The model fields the presentation reads still move it on their own.
        task.status = .failed
        #expect(TaskMissionControlSnapshot.Inputs(task: task, thread: nil, planState: .empty, stateRevision: 0) != key)
    }

    @Test("mission control summarizes source-backed validation and correction state")
    func missionControlSummarizesValidationAndCorrectionState() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Mission", primaryPath: root)
        let task = AgentTask(title: "Mission task", goal: "Ship evidence-gated work", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Mission plan",
            goal: "Ship evidence-gated work",
            steps: [TaskPlanPayloadStep(id: "fix", title: "Fix implementation")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "tests",
                    description: "Focused tests pass",
                    method: .command,
                    command: "swift build --package-path \(root)/missing-package"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let presentation = try #require(MissionControlPresentation.build(
            task: task,
            planState: TaskPlanService.reconstruct(for: task),
            state: state
        ))

        #expect(presentation.statusTitle == "Needs correction")
        #expect(presentation.tone == .failed)
        #expect(presentation.objective == "Ship evidence-gated work")
        #expect(presentation.validationSummary.contains("failed"))
        #expect(presentation.assertionRows.map(\.id) == ["tests"])
        #expect(presentation.correction?.failedAssertionID == "tests")
        #expect(presentation.isSourceBacked)
        #expect(presentation.nextAction?.contains("failed assertion tests") == true)
    }

    @Test("mission control actions are durable task events")
    func missionControlActionsAreDurableTaskEvents() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Mission Actions", primaryPath: root)
        let task = AgentTask(title: "Mission task", goal: "Audit mission actions", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        MissionControlPresentation.recordAction(
            TaskMissionActionEventTypes.dismissed,
            task: task,
            correctiveStepID: "corrective-tests",
            reason: "Not needed",
            modelContext: context
        )

        let event = try #require(task.events.first { $0.type == TaskMissionActionEventTypes.dismissed })
        #expect(event.category == "lifecycle")
        #expect(event.payload.contains("corrective-tests"))
        #expect(event.payload.contains("Not needed"))
    }

    @Test("mission control hides budget metric when budget is disabled")
    func missionControlHidesBudgetMetricWhenBudgetIsDisabled() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Mission Budget", primaryPath: root)
        let task = AgentTask(title: "Budgetless task", goal: "Run without budget", workspace: workspace, tokenBudget: 0)
        context.insert(workspace)
        context.insert(task)
        context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: "Ready"))

        let presentation = try #require(MissionControlPresentation.build(
            task: task,
            planState: TaskPlanState.empty,
            state: nil
        ))

        #expect(presentation.budgetSummary == nil)
    }

    private func makeFinishedSnapshotTask(root: String, context: ModelContext) -> AgentTask {
        let workspace = Workspace(name: "Mission Snapshot", primaryPath: root)
        let task = AgentTask(title: "Snapshot task", goal: "Summarize mission snapshot", workspace: workspace)
        task.status = .completed
        context.insert(workspace)
        context.insert(task)
        let run = TaskRun(task: task)
        run.status = .completed
        run.setOutput("Finished.")
        task.runs = [run]
        context.insert(run)
        return task
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-mission-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
