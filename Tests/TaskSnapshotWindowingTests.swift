import Testing
import AppKit
import SwiftUI
import ASTRAModels
@testable import ASTRA
import ASTRACore

extension TaskThreadSnapshotTests {
    // MARK: - Progressive window expansion

    @Test("Default window keeps last 50 runs and reports omitted count")
    func defaultWindowKeepsLast50Runs() {
        let task = makeTask()
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<100 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)
        }

        let input = TaskThreadSnapshotInput(task: task)
        let snapshot = TaskThreadSnapshot(input: input)

        #expect(input.runs.count == 50)
        #expect(input.omittedRunCount == 50)
        #expect(input.totalRunCount == 100)
        #expect(snapshot.sortedRuns.count == 50)
        #expect(snapshot.latestRun?.output == "run 99")
        #expect(snapshot.sortedRuns.first?.output == "run 50")
        #expect(!snapshot.sortedRuns.contains { $0.output == "run 0" })
    }

    @Test("Custom maxRuns parameter controls window size")
    func customMaxRunsControlsWindowSize() {
        let task = makeTask()
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<100 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)
        }

        let small = TaskThreadSnapshotInput(task: task, maxRuns: 10)
        #expect(small.runs.count == 10)
        #expect(small.omittedRunCount == 90)
        #expect(small.totalRunCount == 100)

        let medium = TaskThreadSnapshotInput(task: task, maxRuns: 75)
        #expect(medium.runs.count == 75)
        #expect(medium.omittedRunCount == 25)

        let oversized = TaskThreadSnapshotInput(task: task, maxRuns: 200)
        #expect(oversized.runs.count == 100)
        #expect(oversized.omittedRunCount == 0)
    }

    @Test("Expanding window reveals earlier runs while keeping latest")
    func expandingWindowRevealsEarlierRuns() {
        let task = makeTask()
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<150 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)

            task.events.append(makeEvent(
                task: task,
                type: "user.message",
                payload: "msg \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i * 100 + 5)),
                run: nil
            ))
        }

        let first = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task, maxRuns: 50))
        #expect(first.sortedRuns.count == 50)
        #expect(first.omittedRunCount == 100)
        #expect(first.latestRun?.output == "run 149")
        #expect(first.sortedRuns.first?.output == "run 100")

        let expanded = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task, maxRuns: 100))
        #expect(expanded.sortedRuns.count == 100)
        #expect(expanded.omittedRunCount == 50)
        #expect(expanded.latestRun?.output == "run 149")
        #expect(expanded.sortedRuns.first?.output == "run 50")

        let full = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task, maxRuns: 200))
        #expect(full.sortedRuns.count == 150)
        #expect(full.omittedRunCount == 0)
        #expect(full.sortedRuns.first?.output == "run 0")
    }

    @Test("Short task with fewer runs than window has zero omitted")
    func shortTaskHasZeroOmitted() {
        let task = makeTask()
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<5 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "run \(i)"
            task.runs.append(run)
        }

        let input = TaskThreadSnapshotInput(task: task)
        let snapshot = TaskThreadSnapshot(input: input)

        #expect(input.runs.count == 5)
        #expect(input.omittedRunCount == 0)
        #expect(snapshot.sortedRuns.count == 5)
        #expect(snapshot.sortedRuns.first?.output == "run 0")
        #expect(snapshot.latestRun?.output == "run 4")
    }

    @Test("Conversation items from windowed snapshot include first user message")
    func windowedSnapshotIncludesGoalMessage() {
        let task = makeTask(goal: "Initial goal")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<100 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.output = "output \(i)"
            task.runs.append(run)

            task.events.append(makeEvent(
                task: task,
                type: "user.message",
                payload: "follow-up \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i * 100 + 95)),
                run: nil
            ))
        }

        let snapshot = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task, maxRuns: 20))

        guard case .userMessage(let goalText, _) = snapshot.conversationItems.first else {
            Issue.record("First conversation item should be the goal user message")
            return
        }
        #expect(goalText == "Initial goal")
        #expect(snapshot.omittedRunCount == 80)

        let agentResponses = snapshot.conversationItems.filter {
            if case .agentResponse = $0 { return true }
            return false
        }
        #expect(agentResponses.count == 20)
    }

    @Test("totalRunCount reflects all runs regardless of window size")
    func totalRunCountReflectsAllRuns() {
        let task = makeTask()
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<200 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 10))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 10 + 9))
            run.output = "r\(i)"
            task.runs.append(run)
        }

        let small = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task, maxRuns: 10))
        #expect(small.totalRunCount == 200)
        #expect(small.sortedRuns.count == 10)

        let medium = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task, maxRuns: 100))
        #expect(medium.totalRunCount == 200)
        #expect(medium.sortedRuns.count == 100)
    }

    @Test("Large deterministic history keeps initial transcript input bounded")
    func largeDeterministicHistoryKeepsInitialTranscriptInputBounded() {
        let task = makeTask(goal: "Large history fixture")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for runIndex in 0..<250 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(runIndex * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(runIndex * 100 + 90))
            run.output = "completed run \(runIndex)"
            task.runs.append(run)

            for eventIndex in 0..<20 {
                task.events.append(makeEvent(
                    task: task,
                    type: eventIndex.isMultiple(of: 2) ? "tool.result" : "agent.response",
                    payload: "event \(runIndex)-\(eventIndex)",
                    timestamp: Date(timeIntervalSince1970: Double(runIndex * 100 + eventIndex)),
                    run: run
                ))
            }
        }

        let input = TaskThreadSnapshotInput(task: task)
        let snapshot = TaskThreadSnapshot(input: input)

        #expect(input.totalRunCount == 250)
        #expect(input.totalEventCount == 5_000)
        #expect(input.runs.count == 50)
        #expect(input.events.count <= 1_200)
        #expect(input.omittedRunCount == 200)
        #expect(input.omittedEventCount >= 3_800)
        #expect(snapshot.sortedRuns.count == 50)
        #expect(snapshot.sortedEvents.count <= 1_200)
    }
}
