import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - TaskThreadSnapshot

@Suite("TaskThreadSnapshot")
struct TaskThreadSnapshotTests {

    @Test("visibleEventCount excludes high-frequency streaming-delta types and is correct regardless of array order")
    func visibleEventCountIsCorrectRegardlessOfOrder() {
        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        task.runs.append(run)

        var expectedVisibleCount = 0
        let typeCycle: [String] = ["agent.response", "tool.use", "agent.thinking", "tool.result", "agent.response"]
        var events: [TaskEvent] = []

        for i in 0..<200 {
            let type = typeCycle[i % typeCycle.count]
            let event = makeEvent(task: task, type: type, payload: "chunk \(i)", timestamp: Date(timeIntervalSince1970: Double(i)), run: run)
            events.append(event)
            if type != "agent.response" && type != "agent.thinking" {
                expectedVisibleCount += 1
            }
        }

        // A plain full scan (no incremental memo, see TaskLiveness's doc comment
        // for why an incremental scan over this relationship array isn't safe)
        // must be correct no matter what order SwiftData hands the array back
        // in — try both the natural order and a shuffled one.
        task.events = events
        #expect(TaskThreadSnapshotTrigger(task: task).visibleEventCount == expectedVisibleCount)

        task.events = events.shuffled()
        #expect(TaskThreadSnapshotTrigger(task: task).visibleEventCount == expectedVisibleCount)
    }

    @Test("visibleEventCount reflects events inserted anywhere in the array, not just at the tail")
    func visibleEventCountReflectsMidArrayInsertion() {
        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        task.runs.append(run)

        let e1 = makeEvent(task: task, type: "tool.use", payload: "e1", timestamp: Date(timeIntervalSince1970: 0), run: run)
        let e2 = makeEvent(task: task, type: "tool.use", payload: "e2", timestamp: Date(timeIntervalSince1970: 1), run: run)
        let e3 = makeEvent(task: task, type: "tool.use", payload: "e3", timestamp: Date(timeIntervalSince1970: 2), run: run)
        task.events = [e1, e2, e3]
        #expect(TaskThreadSnapshotTrigger(task: task).visibleEventCount == 3)

        // Simulates `AgentEventRecorder` inserting a new event through the model
        // context such that the relationship array comes back with the new
        // event landing BEFORE what a naive "new events are appended at the
        // tail" assumption would expect.
        let e4 = makeEvent(task: task, type: "tool.result", payload: "e4", timestamp: Date(timeIntervalSince1970: 1.5), run: run)
        task.events = [e1, e2, e4, e3]
        #expect(TaskThreadSnapshotTrigger(task: task).visibleEventCount == 4)
    }

    @Test("Trigger equality is unaffected by reordering alone, only by count/status changes")
    func triggerEqualityUnaffectedByReorderingAlone() {
        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        task.runs.append(run)

        let e1 = makeEvent(task: task, type: "tool.use", payload: "e1", timestamp: Date(timeIntervalSince1970: 0), run: run)
        let e2 = makeEvent(task: task, type: "agent.response", payload: "e2", timestamp: Date(timeIntervalSince1970: 1), run: run)
        let e3 = makeEvent(task: task, type: "tool.result", payload: "e3", timestamp: Date(timeIntervalSince1970: 2), run: run)
        task.events = [e1, e2, e3]
        let before = TaskThreadSnapshotTrigger(task: task)

        task.events = [e3, e1, e2]
        let afterReorderOnly = TaskThreadSnapshotTrigger(task: task)
        #expect(afterReorderOnly == before, "reordering the same set of events shouldn't change the coarse trigger")

        task.events.append(makeEvent(task: task, type: "tool.use", payload: "e4", timestamp: Date(timeIntervalSince1970: 3), run: run))
        let afterRealChange = TaskThreadSnapshotTrigger(task: task)
        #expect(afterRealChange != before, "a genuinely new visible event must change the trigger")
    }
}

// MARK: - TaskLiveness

@Suite("TaskLiveness")
struct TaskLivenessTests {

    @Test("A running task with a running latest run is live")
    func runningTaskWithRunningRunIsLive() {
        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        run.status = .running
        run.startedAt = Date(timeIntervalSince1970: 0)
        task.runs.append(run)
        #expect(TaskLiveness.isLive(task: task))
    }

    @Test("A running task with no runs yet is not live — task.status alone doesn't guarantee a run has actually started")
    func runningTaskWithNoRunsIsNotLive() {
        // Regression test: TaskQueue.continueSession owns the continuation
        // admission transition to .running, then the worker creates the run.
        // Treating task.status == .running alone as live can poll a large
        // history during that narrow launch handoff, even though no run — and
        // so no new content — exists yet.
        let task = makeTask(status: .running)
        #expect(!TaskLiveness.isLive(task: task))
    }

    @Test("A queued task (waiting behind another run) is not live — nothing to poll until it actually starts running")
    func queuedTaskIsNotLive() {
        let task = makeTask(status: .queued)
        #expect(!TaskLiveness.isLive(task: task))
    }

    @Test("A pending-user task with a still-running latest run is not live — a permission pause isn't streaming")
    func pendingUserTaskWithRunningRunIsNotLive() {
        // Regression test: AgentInteractivePermissionChannel sets
        // task.status = .pendingUser for a permission prompt while leaving
        // run.status == .running until the user decides. Treating the run's
        // status alone as live re-polled a large event history every tick for
        // as long as the prompt went unanswered, even though the provider is
        // paused and nothing is actually streaming.
        let task = makeTask(status: .pendingUser)
        let run = TaskRun(task: task)
        run.status = .running
        run.startedAt = Date(timeIntervalSince1970: 0)
        task.runs.append(run)
        #expect(!TaskLiveness.isLive(task: task))
    }

    @Test("A completed task with a running latest run is not live — task.status must also say running")
    func completedTaskWithRunningLatestRunIsNotLive() {
        let task = makeTask(status: .completed)
        let run = TaskRun(task: task)
        run.status = .running
        run.startedAt = Date(timeIntervalSince1970: 0)
        task.runs.append(run)
        #expect(!TaskLiveness.isLive(task: task))
    }

    @Test("A completed task with only completed runs is not live")
    func completedTaskWithCompletedRunsIsNotLive() {
        let task = makeTask(status: .completed)
        let run = TaskRun(task: task)
        run.status = .completed
        run.startedAt = Date(timeIntervalSince1970: 0)
        task.runs.append(run)
        #expect(!TaskLiveness.isLive(task: task))
    }

    @Test("Liveness is based on the latest run by startedAt, not array order")
    func livenessUsesLatestRunByStartedAt() {
        let task = makeTask(status: .running)
        let olderRunning = TaskRun(task: task)
        olderRunning.status = .running
        olderRunning.startedAt = Date(timeIntervalSince1970: 0)
        let newerCompleted = TaskRun(task: task)
        newerCompleted.status = .completed
        newerCompleted.startedAt = Date(timeIntervalSince1970: 100)
        task.runs = [newerCompleted, olderRunning]

        #expect(!TaskLiveness.isLive(task: task), "the latest run by startedAt is completed, so the task isn't live even though an older run is still marked running")
    }
}
