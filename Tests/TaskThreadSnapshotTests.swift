import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - TaskThreadSnapshot

@Suite("TaskThreadSnapshot")
struct TaskThreadSnapshotTests {

    @Test("Incremental visible-event-count memo matches a full rescan as events stream in")
    func incrementalVisibleEventCountMatchesFullRescan() {
        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()

        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        task.runs.append(run)

        var expectedVisibleCount = 0
        let typeCycle: [String] = ["agent.response", "tool.use", "agent.thinking", "tool.result", "agent.response"]

        for i in 0..<500 {
            let type = typeCycle[i % typeCycle.count]
            task.events.append(makeEvent(task: task, type: type, payload: "chunk \(i)", timestamp: Date(timeIntervalSince1970: Double(i)), run: run))
            if type != "agent.response" && type != "agent.thinking" {
                expectedVisibleCount += 1
            }

            // Only re-derive the trigger every few events, like SwiftUI re-evaluating
            // the observer at irregular points, to exercise both the "one new event"
            // and "several new events since last call" incremental-scan paths.
            guard i % 3 == 0 || i == 499 else { continue }
            let trigger = TaskThreadSnapshotTrigger(task: task)
            #expect(trigger.eventCount == task.events.count)
            #expect(trigger.visibleEventCount == expectedVisibleCount)
        }

        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()
    }

    @Test("Incremental visible-event-count memo recovers correctly after switching tasks")
    func incrementalVisibleEventCountRecoversAfterTaskSwitch() {
        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()

        let taskA = makeTask(status: .running)
        let runA = TaskRun(task: taskA)
        taskA.runs.append(runA)
        taskA.events.append(makeEvent(task: taskA, type: "tool.use", payload: "a1", timestamp: Date(timeIntervalSince1970: 0), run: runA))
        taskA.events.append(makeEvent(task: taskA, type: "agent.response", payload: "a2", timestamp: Date(timeIntervalSince1970: 1), run: runA))
        let triggerA = TaskThreadSnapshotTrigger(task: taskA)
        #expect(triggerA.visibleEventCount == 1)

        // Switching to a different task must not carry over taskA's scanned-count
        // state (which would either under- or over-count taskB's events).
        let taskB = makeTask(status: .running)
        let runB = TaskRun(task: taskB)
        taskB.runs.append(runB)
        for i in 0..<5 {
            taskB.events.append(makeEvent(task: taskB, type: "tool.use", payload: "b\(i)", timestamp: Date(timeIntervalSince1970: Double(i)), run: runB))
        }
        let triggerB = TaskThreadSnapshotTrigger(task: taskB)
        #expect(triggerB.visibleEventCount == 5)

        // Switching back to taskA must also recover correctly, not resume from
        // taskB's now-larger scanned count.
        taskA.events.append(makeEvent(task: taskA, type: "tool.result", payload: "a3", timestamp: Date(timeIntervalSince1970: 2), run: runA))
        let triggerA2 = TaskThreadSnapshotTrigger(task: taskA)
        #expect(triggerA2.visibleEventCount == 2)

        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()
    }

    @Test("Incremental visible-event-count memo self-heals when a new event lands before the scan boundary")
    func incrementalVisibleEventCountSelfHealsOnMidArrayInsertion() {
        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()

        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        task.runs.append(run)

        let e1 = makeEvent(task: task, type: "tool.use", payload: "e1", timestamp: Date(timeIntervalSince1970: 0), run: run)
        let e2 = makeEvent(task: task, type: "tool.use", payload: "e2", timestamp: Date(timeIntervalSince1970: 1), run: run)
        let e3 = makeEvent(task: task, type: "tool.use", payload: "e3", timestamp: Date(timeIntervalSince1970: 2), run: run)
        task.events = [e1, e2, e3]

        let firstTrigger = TaskThreadSnapshotTrigger(task: task)
        #expect(firstTrigger.visibleEventCount == 3)

        // Simulate `AgentEventRecorder` inserting a new event through the model
        // context such that the relationship array comes back reordered, landing
        // the new event BEFORE the previous scan boundary (index 2) instead of
        // appended at the tail — exactly the case an index-only incremental scan
        // would silently miscount (it would double-count e3 at the old boundary
        // and never see e4 at all, since e4 now hides inside the "already
        // scanned" prefix).
        let e4 = makeEvent(task: task, type: "tool.result", payload: "e4", timestamp: Date(timeIntervalSince1970: 1.5), run: run)
        task.events = [e1, e2, e4, e3]

        let secondTrigger = TaskThreadSnapshotTrigger(task: task)
        #expect(secondTrigger.eventCount == 4)
        #expect(secondTrigger.visibleEventCount == 4, "the boundary-identity check must detect the shift and fall back to a full rescan")

        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()
    }

    @Test("Incremental visible-event-count memo is unaffected by reordering within the already-counted prefix")
    func incrementalVisibleEventCountUnaffectedByReorderingWithinCountedPrefix() {
        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()

        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        task.runs.append(run)

        let e1 = makeEvent(task: task, type: "tool.use", payload: "e1", timestamp: Date(timeIntervalSince1970: 0), run: run)
        let e2 = makeEvent(task: task, type: "agent.response", payload: "e2", timestamp: Date(timeIntervalSince1970: 1), run: run)
        let e3 = makeEvent(task: task, type: "tool.result", payload: "e3", timestamp: Date(timeIntervalSince1970: 2), run: run)
        task.events = [e1, e2, e3]
        _ = TaskThreadSnapshotTrigger(task: task)

        // The last element (the scan boundary) is unchanged, but e1/e2 swapped
        // places ahead of it — a pure permutation of the already-counted set.
        // The boundary check passes (same tail element), and since counting by
        // type doesn't care about order, the incremental path stays correct here.
        task.events = [e2, e1, e3]
        let e4 = makeEvent(task: task, type: "tool.use", payload: "e4", timestamp: Date(timeIntervalSince1970: 3), run: run)
        task.events.append(e4)

        let trigger = TaskThreadSnapshotTrigger(task: task)
        #expect(trigger.eventCount == 4)
        #expect(trigger.visibleEventCount == 3, "e1, e3, e4 are visible; e2 (agent.response) is not")

        TaskThreadSnapshotTrigger.resetVisibleEventCountMemoForTesting()
    }
}
