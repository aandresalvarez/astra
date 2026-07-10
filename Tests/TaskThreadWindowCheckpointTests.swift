import Testing
import AppKit
import SwiftUI
import ASTRAModels
@testable import ASTRA
import ASTRACore

// MARK: - TaskThreadViewModel progressive window

@Suite("TaskThreadViewModel")
struct TaskThreadViewModelTests {

    @MainActor
    private func awaitSnapshot(
        _ vm: TaskThreadViewModel,
        where predicate: @Sendable (TaskThreadSnapshot) -> Bool,
        timeout: TimeInterval = 30
    ) async -> TaskThreadSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snap = vm.snapshot, predicate(snap) {
                return snap
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return vm.snapshot
    }

    @MainActor
    private func awaitReadiness(
        _ vm: TaskThreadViewModel,
        taskID: UUID,
        timeout: TimeInterval = 30
    ) async -> TaskThreadSnapshotReadiness {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let readiness = vm.appliedSnapshotReadiness
            if readiness.isReady(for: taskID) {
                return readiness
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return vm.appliedSnapshotReadiness
    }

    @MainActor
    @Test("ViewModel starts with default 50-run window")
    func viewModelStartsWithDefaultWindow() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<100 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)
        }

        vm.reset(for: task)

        guard let snapshot = await awaitSnapshot(vm, where: { $0.sortedRuns.count > 0 }) else {
            Issue.record("Snapshot should be built after reset")
            return
        }
        #expect(snapshot.sortedRuns.count == 50)
        #expect(snapshot.omittedRunCount == 50)
        #expect(snapshot.latestRun?.output == "run 99")
        #expect(vm.appliedSnapshotRevision > 0)
        #expect(vm.appliedSnapshotTaskID == task.id)
        #expect(vm.lastSnapshotCacheState == "not_applicable")
    }

    @MainActor
    @Test("Reset clears the previous task readiness before applying the next snapshot")
    func resetClearsPreviousTaskReadiness() async {
        let vm = TaskThreadViewModel()
        let firstTask = makeTask(goal: "First task")
        let secondTask = makeTask(goal: "Second task")
        firstTask.runs.append(TaskRun(task: firstTask))

        vm.reset(for: firstTask)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 1 })
        #expect(vm.appliedSnapshotTaskID == firstTask.id)
        #expect(vm.appliedSnapshotRevision > 0)

        vm.reset(for: secondTask)

        #expect(vm.appliedSnapshotTaskID == nil)
        #expect(vm.appliedSnapshotRevision == 0)
        // refreshSnapshot resolves cache eligibility synchronously during
        // reset, before the detached snapshot has been applied.
        #expect(vm.lastSnapshotCacheState == "not_applicable")
    }

    @MainActor
    @Test("Applied empty snapshot advances readiness even when placeholder geometry matches")
    func appliedEmptySnapshotAdvancesReadiness() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Only the initial goal")

        vm.reset(for: task)
        let pendingReadiness = vm.appliedSnapshotReadiness
        let appliedReadiness = await awaitReadiness(vm, taskID: task.id)

        #expect(!pendingReadiness.isReady(for: task.id))
        #expect(appliedReadiness.isReady(for: task.id))
        #expect(appliedReadiness != pendingReadiness)
        #expect(vm.snapshot?.sortedRuns.isEmpty == true)
        #expect(vm.snapshot?.sortedEvents.isEmpty == true)
    }

    @MainActor
    @Test("expandWindow increases the run window and rebuilds snapshot")
    func expandWindowIncreasesRunWindow() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<150 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })

        #expect(vm.snapshot?.sortedRuns.count == 50)
        #expect(vm.snapshot?.omittedRunCount == 100)

        vm.expandWindow(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 100 })

        #expect(vm.snapshot?.sortedRuns.count == 100)
        #expect(vm.snapshot?.omittedRunCount == 50)
        #expect(vm.snapshot?.latestRun?.output == "run 149")

        vm.expandWindow(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 150 })

        #expect(vm.snapshot?.sortedRuns.count == 150)
        #expect(vm.snapshot?.omittedRunCount == 0)
    }

    @MainActor
    @Test("expandWindow is a no-op when no runs are omitted")
    func expandWindowNoOpWhenNoOmitted() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<10 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 10 })

        #expect(vm.snapshot?.sortedRuns.count == 10)
        #expect(vm.snapshot?.omittedRunCount == 0)

        vm.expandWindow(for: task)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(vm.snapshot?.sortedRuns.count == 10)
        #expect(vm.snapshot?.omittedRunCount == 0)
    }

    @MainActor
    @Test("reset restores the default window after expansion")
    func resetRestoresDefaultWindow() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<120 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })
        #expect(vm.snapshot?.sortedRuns.count == 50)

        vm.expandWindow(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 100 })
        #expect(vm.snapshot?.sortedRuns.count == 100)

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })
        #expect(vm.snapshot?.sortedRuns.count == 50)
        #expect(vm.snapshot?.omittedRunCount == 70)
    }

    @MainActor
    @Test("Completed large task reset reuses terminal snapshot cache")
    func completedLargeTaskResetReusesTerminalSnapshotCache() async {
        TaskThreadViewModel.resetSnapshotCacheForTesting()

        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Summarize a large completed task", status: .completed)
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.completedAt = Date(timeIntervalSince1970: 30_000)

        for i in 0..<220 {
            let run = TaskRun(task: task)
            run.status = .completed
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "completed run \(i)"
            task.runs.append(run)

            let event = TaskEvent(task: task, type: "agent.response", payload: "response \(i)", run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(i * 100 + 95))
            task.events.append(event)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })

        let firstStats = TaskThreadViewModel.snapshotCacheStatsForTesting
        #expect(firstStats.entryCount == 1)
        #expect(firstStats.missCount == 1)
        #expect(firstStats.hitCount == 0)
        #expect(vm.lastSnapshotCacheState == "miss")

        vm.reset(for: task)

        let secondStats = TaskThreadViewModel.snapshotCacheStatsForTesting
        #expect(vm.snapshot?.sortedRuns.count == 50)
        #expect(vm.snapshot?.omittedRunCount == 170)
        #expect(secondStats.entryCount == 1)
        #expect(secondStats.hitCount == 1)
        #expect(secondStats.missCount == 1)
        #expect(vm.lastSnapshotCacheState == "hit")

        TaskThreadViewModel.resetSnapshotCacheForTesting()
    }

    @MainActor
    @Test("Terminal snapshot cache key stores a goal fingerprint instead of full goal text")
    func terminalSnapshotCacheKeyStoresGoalFingerprintInsteadOfFullGoalText() throws {
        let task = makeTask(
            goal: String(repeating: "Long goal with expensive retained text. ", count: 300),
            status: .completed
        )
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.completedAt = Date(timeIntervalSince1970: 100)
        let trigger = TaskThreadSnapshotTrigger(task: task)
        let key = try #require(TaskThreadSnapshotCacheKey(task: task, trigger: trigger, maxRuns: 50))

        let fieldNames = Set(Mirror(reflecting: key).children.compactMap(\.label))
        #expect(fieldNames.contains("goalHash"))
        #expect(!fieldNames.contains("goal"))
    }

    @Test("Task thread view model reuses one cache key for terminal snapshot lookup and storage")
    func taskThreadViewModelReusesOneCacheKeyForTerminalSnapshotLookupAndStorage() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/Views/TaskThreadViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let constructorCount = source.components(separatedBy: "TaskThreadSnapshotCacheKey(task:").count - 1

        #expect(constructorCount == 1)
    }
}

// MARK: - TaskCheckpointPresentation

@Suite("TaskCheckpointPresentation")
struct TaskCheckpointPresentationTests {

    @Test("Checkpoint comparison separates restored branch from later task history")
    func checkpointComparisonSeparatesRestoredBranchFromLaterHistory() throws {
        let task = makeTask(goal: "Try alternative implementation branches")
        let first = makeCheckpointRun(
            task: task,
            index: 0,
            output: "First branch created the model.",
            tokens: 100,
            filePaths: ["/tmp/model.swift"]
        )
        let second = makeCheckpointRun(
            task: task,
            index: 1,
            output: "Second branch wired the checkpoint browser.",
            tokens: 200,
            filePaths: ["/tmp/browser.swift"]
        )
        let third = makeCheckpointRun(
            task: task,
            index: 2,
            output: "Later branch changed the restore path.",
            tokens: 300,
            filePaths: ["/tmp/restore.swift"]
        )

        let summaries = TaskCheckpointPresentation.summaries(from: [third, first, second].map(runSnapshot))
        let comparison = try #require(TaskCheckpointPresentation.comparison(for: second.id, in: summaries))

        #expect(summaries.map(\.run.id) == [first.id, second.id, third.id])
        #expect(comparison.selected.stepNumber == 2)
        #expect(comparison.includedRunCount == 2)
        #expect(comparison.excludedRunCount == 1)
        #expect(comparison.includedTokenCount == 300)
        #expect(comparison.excludedTokenCount == 300)
        #expect(comparison.includedFileCount == 2)
        #expect(comparison.excludedFileCount == 1)
        #expect(comparison.includedFiles == ["/tmp/model.swift", "/tmp/browser.swift"])
        #expect(comparison.excludedFiles == ["/tmp/restore.swift"])
        #expect(comparison.selected.outputPreview.contains("checkpoint browser"))
        #expect(comparison.laterOutputPreview.contains("restore path"))
        #expect(comparison.branchSummary == "1 later step will stay on the current task.")
        #expect(comparison.canRestore)
        #expect(TaskCheckpointPresentation.restoreActionTitle == "Restore as New Branch")
    }

    @Test("Checkpoint file counts match deduplicated file lists")
    func checkpointFileCountsMatchDeduplicatedFileLists() throws {
        let task = makeTask(goal: "Compare repeated file changes")
        let first = makeCheckpointRun(
            task: task,
            index: 0,
            output: "First edit.",
            tokens: 100,
            filePaths: ["/tmp/shared.swift"]
        )
        let second = makeCheckpointRun(
            task: task,
            index: 1,
            output: "Second edit repeats shared files.",
            tokens: 200,
            filePaths: ["/tmp/shared.swift", "/tmp/unique.swift", "/tmp/unique.swift"]
        )
        let third = makeCheckpointRun(
            task: task,
            index: 2,
            output: "Later edit repeats another file.",
            tokens: 300,
            filePaths: ["/tmp/later.swift", "/tmp/later.swift"]
        )

        let summaries = TaskCheckpointPresentation.summaries(from: [first, second, third].map(runSnapshot))
        let comparison = try #require(TaskCheckpointPresentation.comparison(for: second.id, in: summaries))

        #expect(summaries.map(\.fileCount) == [1, 2, 1])
        #expect(comparison.includedFiles == ["/tmp/shared.swift", "/tmp/unique.swift"])
        #expect(comparison.excludedFiles == ["/tmp/later.swift"])
        #expect(comparison.includedFileCount == comparison.includedFiles.count)
        #expect(comparison.excludedFileCount == comparison.excludedFiles.count)
    }

    @Test("Running checkpoint cannot be restored from browser")
    func runningCheckpointCannotBeRestoredFromBrowser() throws {
        let task = makeTask()
        let run = makeCheckpointRun(
            task: task,
            index: 0,
            status: .running,
            completed: nil,
            output: "Still streaming.",
            tokens: 10,
            filePaths: []
        )

        let summaries = TaskCheckpointPresentation.summaries(from: [runSnapshot(run)])
        let comparison = try #require(TaskCheckpointPresentation.comparison(for: run.id, in: summaries))

        #expect(!comparison.canRestore)
        #expect(comparison.restoreDisabledReason == "Wait for this step to finish before restoring from it.")
    }

    private func makeCheckpointRun(
        task: AgentTask,
        index: Int,
        status: RunStatus = .completed,
        completed: Date? = nil,
        output: String,
        tokens: Int,
        filePaths: [String]
    ) -> TaskRun {
        let run = TaskRun(task: task)
        run.status = status
        run.startedAt = Date(timeIntervalSince1970: Double(index * 100))
        run.completedAt = completed ?? (status == .running ? nil : Date(timeIntervalSince1970: Double(index * 100 + 20)))
        run.output = output
        run.tokensUsed = tokens

        for path in filePaths {
            run.appendFileChange(StoredFileChange(
                from: FileChange(
                    path: path,
                    changeType: .write,
                    content: "content",
                    oldString: nil,
                    newString: nil,
                    timestamp: run.startedAt
                )
            ))
        }

        return run
    }

    private func runSnapshot(_ run: TaskRun) -> TaskRunSnapshot {
        TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))
    }
}
