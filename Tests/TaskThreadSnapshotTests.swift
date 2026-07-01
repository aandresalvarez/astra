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
}
