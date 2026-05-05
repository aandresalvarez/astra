import Foundation
import Testing
@testable import ASTRA

@Suite("Task Runtime Health")
struct TaskRuntimeHealthTests {
    @Test("Recent response activity is active")
    func recentResponseIsActive() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = SnapshotFixture(now: now)
        fixture.addEvent(type: "agent.response", payload: "Working", secondsAgo: 30)

        let health = TaskRuntimeHealth.evaluate(
            taskStatus: .running,
            snapshot: fixture.snapshot(),
            now: now
        )

        #expect(health.state == .active)
        #expect(health.message == "Writing response...")
    }

    @Test("Long quiet running task is quiet")
    func quietRunningTask() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = SnapshotFixture(now: now)
        fixture.addEvent(type: "tool.result", payload: "done", secondsAgo: 420)

        let health = TaskRuntimeHealth.evaluate(
            taskStatus: .running,
            snapshot: fixture.snapshot(),
            now: now
        )

        #expect(health.state == .quiet)
        #expect(health.message.contains("last activity 7m ago"))
    }

    @Test("Permission denied followed by later activity is recovered")
    func permissionWarningRecovered() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = SnapshotFixture(now: now)
        fixture.addEvent(type: "permission.denied", payload: "Permission denied for tool: Bash. blocked", secondsAgo: 90)
        fixture.addEvent(type: "agent.response", payload: "Continuing", secondsAgo: 20)

        let health = TaskRuntimeHealth.evaluate(
            taskStatus: .running,
            snapshot: fixture.snapshot(),
            now: now
        )

        #expect(health.state == .recoveredWarning)
        #expect(health.message == "Permission warning recovered for Bash")
    }

    @Test("Permission denied without later activity becomes possibly stalled")
    func permissionWarningPossiblyStalled() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = SnapshotFixture(now: now)
        fixture.addEvent(type: "permission.denied", payload: "Permission denied for tool: Bash. blocked", secondsAgo: 360)

        let health = TaskRuntimeHealth.evaluate(
            taskStatus: .running,
            snapshot: fixture.snapshot(),
            now: now
        )

        #expect(health.state == .possiblyStalled)
        #expect(health.isAttentionState)
    }

    @Test("Completed task after warning is not running")
    func completedTaskAfterWarningIsNotRunning() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = SnapshotFixture(now: now)
        fixture.addEvent(type: "permission.denied", payload: "Permission denied for tool: Bash. blocked", secondsAgo: 360)
        fixture.run.status = .completed
        fixture.run.completedAt = now.addingTimeInterval(-20)

        let health = TaskRuntimeHealth.evaluate(
            taskStatus: .completed,
            snapshot: fixture.snapshot(),
            now: now
        )

        #expect(health.state == .notRunning)
    }
}

private final class SnapshotFixture {
    let now: Date
    let task: AgentTask
    let run: TaskRun
    private var events: [TaskEvent] = []

    init(now: Date) {
        self.now = now
        task = AgentTask(title: "Task", goal: "Goal")
        task.status = .running
        run = TaskRun(task: task)
        run.startedAt = now.addingTimeInterval(-600)
        run.status = .running
    }

    func addEvent(type: String, payload: String, secondsAgo: TimeInterval) {
        let event = TaskEvent(task: task, type: type, payload: payload, run: run)
        event.timestamp = now.addingTimeInterval(-secondsAgo)
        events.append(event)
    }

    func snapshot() -> TaskThreadSnapshot {
        TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: events, runs: [run])
    }
}
