import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

private func makeContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

// MARK: - TaskSchedule Model

@Suite("TaskSchedule advanceNextFireDate")
@MainActor
struct ScheduleAdvanceTests {

    @Test("Once schedule disables after fire")
    func onceDisables() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let schedule = TaskSchedule(name: "Once", scheduleType: .once)
        ctx.insert(schedule)
        try ctx.save()

        #expect(schedule.isEnabled == true)
        schedule.advanceNextFireDate()
        #expect(schedule.isEnabled == false)
    }

    @Test("Interval schedule advances by intervalSeconds")
    func intervalAdvances() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let schedule = TaskSchedule(name: "Hourly", scheduleType: .interval)
        schedule.intervalSeconds = 3600
        ctx.insert(schedule)
        try ctx.save()

        let before = Date()
        schedule.advanceNextFireDate()
        let expected = before.addingTimeInterval(3600)
        #expect(abs(schedule.nextFireDate.timeIntervalSince(expected)) < 2)
    }

    @Test("Daily schedule advances to next occurrence of target hour")
    func dailyAdvances() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let schedule = TaskSchedule(name: "Daily", scheduleType: .daily)
        schedule.dailyHour = 9
        schedule.dailyMinute = 30
        ctx.insert(schedule)
        try ctx.save()

        schedule.advanceNextFireDate()
        let components = Calendar.current.dateComponents([.hour, .minute], from: schedule.nextFireDate)
        #expect(components.hour == 9)
        #expect(components.minute == 30)
        #expect(schedule.nextFireDate > Date())
    }

    @Test("Weekly schedule advances to correct day of week")
    func weeklyAdvances() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let schedule = TaskSchedule(name: "Weekly", scheduleType: .weekly)
        schedule.dailyHour = 10
        schedule.dailyMinute = 0
        schedule.weeklyDayOfWeek = 2  // Monday
        ctx.insert(schedule)
        try ctx.save()

        schedule.advanceNextFireDate()
        let components = Calendar.current.dateComponents([.weekday, .hour, .minute], from: schedule.nextFireDate)
        #expect(components.weekday == 2)
        #expect(components.hour == 10)
        #expect(components.minute == 0)
        #expect(schedule.nextFireDate > Date())
    }
}

@Suite("TaskSchedule Properties")
@MainActor
struct SchedulePropertyTests {

    @Test("effectiveGoal includes conversation context when set")
    func effectiveGoalWithContext() {
        let schedule = TaskSchedule(name: "Test", goal: "Run tests")
        schedule.conversationContext = "User wants unit tests only"
        let goal = schedule.effectiveGoal
        #expect(goal.contains("Run tests"))
        #expect(goal.contains("User wants unit tests only"))
    }

    @Test("effectiveGoal is just goal when no context")
    func effectiveGoalSimple() {
        let schedule = TaskSchedule(name: "Test", goal: "Run tests")
        #expect(schedule.effectiveGoal == "Run tests")
    }

    @Test("templateVariables round-trip through JSON")
    func templateVariables() {
        let schedule = TaskSchedule(name: "Test")
        schedule.templateVariables = ["file": "main.swift", "mode": "strict"]
        let vars = schedule.templateVariables
        #expect(vars["file"] == "main.swift")
        #expect(vars["mode"] == "strict")
    }

    @Test("routine metadata round-trips without polluting template variables")
    func routineMetadata() {
        let schedule = TaskSchedule(name: "Daily Tickets", goal: "Review assigned Jira tickets")
        schedule.templateVariables = ["project": "SUPPORT"]
        schedule.routineDescription = "Daily support triage"
        schedule.routinePaths = ["/tmp/support-docs", "/tmp/support-docs", "docs", "  "]

        #expect(schedule.routineDescription == "Daily support triage")
        #expect(schedule.routineInstructions == "Review assigned Jira tickets")
        #expect(schedule.routinePaths == ["/tmp/support-docs"])
        #expect(schedule.templateSubstitutionVariables == ["project": "SUPPORT"])
    }

    @Test("effectiveGoal includes routine description and folders")
    func effectiveGoalWithRoutineMetadata() {
        let schedule = TaskSchedule(name: "Daily Tickets", goal: "Review assigned Jira tickets")
        schedule.routineDescription = "Daily support triage"
        schedule.routinePaths = ["/tmp/support-docs"]

        let goal = schedule.effectiveGoal
        #expect(goal.contains("Routine description:"))
        #expect(goal.contains("Daily support triage"))
        #expect(goal.contains("Routine instructions:"))
        #expect(goal.contains("Review assigned Jira tickets"))
        #expect(goal.contains("/tmp/support-docs"))
    }

    @Test("runtimeID resolves to a stable provider")
    func runtimeIDResolution() {
        let defaultSchedule = TaskSchedule(name: "Default")
        #expect(defaultSchedule.resolvedRuntimeID == .claudeCode)

        let copilotSchedule = TaskSchedule(name: "Copilot", runtimeID: AgentRuntimeID.copilotCLI.rawValue, model: "gpt-5")
        #expect(copilotSchedule.resolvedRuntimeID == .copilotCLI)
    }

    @Test("frequencySummary for each type")
    func frequencySummary() {
        let once = TaskSchedule(name: "T", scheduleType: .once)
        #expect(once.frequencySummary == "Once")

        let hourly = TaskSchedule(name: "T", scheduleType: .interval)
        hourly.intervalSeconds = 3600
        #expect(hourly.frequencySummary == "Hourly")

        let every30m = TaskSchedule(name: "T", scheduleType: .interval)
        every30m.intervalSeconds = 1800
        #expect(every30m.frequencySummary == "Every 30m")

        let daily = TaskSchedule(name: "T", scheduleType: .daily)
        daily.dailyHour = 9
        daily.dailyMinute = 0
        #expect(daily.frequencySummary == "Daily at 09:00")

        let weekly = TaskSchedule(name: "T", scheduleType: .weekly)
        weekly.weeklyDayOfWeek = 2
        weekly.dailyHour = 10
        weekly.dailyMinute = 0
        #expect(weekly.frequencySummary == "Mon at 10:00")
    }

    @Test("appendRunResult keeps last 50")
    func runResultCap() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let schedule = TaskSchedule(name: "Test")
        ctx.insert(schedule)
        try ctx.save()

        for i in 0..<60 {
            schedule.appendRunResult(status: "completed", summary: "Run \(i)", taskID: UUID())
        }
        #expect(schedule.runResults.count == 50)
        #expect(schedule.runResults.last?.summary == "Run 59")
    }
}

// MARK: - TaskScheduler Lifecycle

@Suite("TaskScheduler Lifecycle")
@MainActor
struct SchedulerLifecycleTests {

    @Test("Scheduler starts and stops cleanly")
    func startStop() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let scheduler = TaskScheduler()
        let queue = TaskQueue()

        #expect(scheduler.isRunning == false)
        scheduler.start(modelContext: ctx, taskQueue: queue)
        #expect(scheduler.isRunning == true)
        scheduler.stop()
    }

    @Test("Double start is a no-op")
    func doubleStart() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let scheduler = TaskScheduler()
        let queue = TaskQueue()

        scheduler.start(modelContext: ctx, taskQueue: queue)
        scheduler.start(modelContext: ctx, taskQueue: queue)
        #expect(scheduler.isRunning == true)
        scheduler.stop()
    }

    @Test("Queue wake requests coalesce while processing is pending")
    func queueWakeCoalescesWhilePending() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let queue = TaskQueue()

        #expect(queue.processQueueIfIdle(modelContext: ctx) == true)
        #expect(queue.processQueueIfIdle(modelContext: ctx) == false)
        #expect(queue.hasProcessingLoop)

        queue.cancelAll()
        #expect(!queue.hasProcessingLoop)
    }

    @Test("Firing a schedule wakes the queue instead of directly executing it")
    func fireScheduleWakesQueue() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let scheduler = TaskScheduler()
        let queue = TaskQueue()
        let workspace = Workspace(
            name: "Scheduled Work",
            primaryPath: "/tmp/astra_scheduler_\(UUID().uuidString)"
        )
        let schedule = TaskSchedule(name: "Routine", goal: "Run routine", workspace: workspace)

        ctx.insert(workspace)
        ctx.insert(schedule)
        try ctx.save()

        scheduler.fireSchedule(schedule, modelContext: ctx, taskQueue: queue)

        let scheduledTasks = workspace.tasks.filter { $0.originScheduleID == schedule.id }
        #expect(scheduledTasks.count == 1)
        #expect(scheduledTasks.first?.status == .queued)
        #expect(queue.activeTasks.isEmpty)
        #expect(queue.hasProcessingLoop)
        #expect(queue.processQueueIfIdle(modelContext: ctx) == false)

        queue.cancelAll()
    }
}

@Suite("TaskLifecycleCoordinator Schedule Visibility")
@MainActor
struct TaskLifecycleCoordinatorScheduleVisibilityTests {

    @Test("Same-thread schedules only show on their source task")
    func sameThreadSchedulesOnlyShowOnTheirSourceTask() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let workspace = Workspace(name: "Schedule Scope", primaryPath: "/tmp/schedule-scope")
        let sourceTask = AgentTask(title: "Source", goal: "Original task", workspace: workspace)
        let otherTask = AgentTask(title: "Other", goal: "Different task", workspace: workspace)

        ctx.insert(workspace)
        ctx.insert(sourceTask)
        ctx.insert(otherTask)

        let sourceSchedule = TaskSchedule(name: "A Source Schedule", goal: "Run source", workspace: workspace)
        sourceSchedule.resultMode = .sameThread
        sourceSchedule.sourceTaskID = sourceTask.id

        let otherSchedule = TaskSchedule(name: "B Other Schedule", goal: "Run other", workspace: workspace)
        otherSchedule.resultMode = .sameThread
        otherSchedule.sourceTaskID = otherTask.id

        let scheduleLogOnly = TaskSchedule(name: "C Schedule Log", goal: "Log only", workspace: workspace)
        scheduleLogOnly.resultMode = .scheduleLog
        scheduleLogOnly.sourceTaskID = sourceTask.id

        let disabledSourceSchedule = TaskSchedule(name: "D Disabled", goal: "Disabled", workspace: workspace)
        disabledSourceSchedule.resultMode = .sameThread
        disabledSourceSchedule.sourceTaskID = sourceTask.id
        disabledSourceSchedule.isEnabled = false

        let unscopedSchedule = TaskSchedule(name: "E Unscoped", goal: "No source", workspace: workspace)
        unscopedSchedule.resultMode = .sameThread

        for schedule in [sourceSchedule, otherSchedule, scheduleLogOnly, disabledSourceSchedule, unscopedSchedule] {
            ctx.insert(schedule)
        }
        try ctx.save()

        let coordinator = TaskLifecycleCoordinator(modelContext: ctx, taskQueue: TaskQueue())

        #expect(coordinator.activeSameThreadSchedules(for: sourceTask).map(\.id) == [sourceSchedule.id])
        #expect(coordinator.activeSameThreadSchedules(for: otherTask).map(\.id) == [otherSchedule.id])
    }
}

// MARK: - Schedule Firing Logic (model-level)

@Suite("Schedule Fire Logic")
@MainActor
struct ScheduleFireLogicTests {

    @Test("Task created from schedule has correct title and goal")
    func taskCreationPattern() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/fire-logic")
        ctx.insert(ws)
        let schedule = TaskSchedule(name: "Nightly Build", goal: "Run full test suite", workspace: ws)
        ctx.insert(schedule)
        try ctx.save()

        let task = AgentTask(
            title: "\(schedule.name) — fired",
            goal: schedule.effectiveGoal,
            workspace: ws,
            tokenBudget: schedule.tokenBudget,
            model: schedule.model
        )
        task.status = .queued
        task.originScheduleID = schedule.id
        ctx.insert(task)

        #expect(task.title.contains("Nightly Build"))
        #expect(task.goal == "Run full test suite")
        #expect(task.status == .queued)
        #expect(task.originScheduleID == schedule.id)
    }

    @Test("Schedule state updates on fire")
    func stateUpdatesOnFire() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let schedule = TaskSchedule(name: "Test", scheduleType: .interval)
        schedule.intervalSeconds = 3600
        ctx.insert(schedule)
        try ctx.save()

        #expect(schedule.fireCount == 0)
        #expect(schedule.lastFiredAt == nil)

        schedule.lastFiredAt = Date()
        schedule.fireCount += 1
        schedule.advanceNextFireDate()

        #expect(schedule.fireCount == 1)
        #expect(schedule.lastFiredAt != nil)
        #expect(schedule.nextFireDate > Date())
    }

    @Test("Once schedule disables after firing")
    func onceDisablesOnFire() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let schedule = TaskSchedule(name: "One-shot", scheduleType: .once)
        ctx.insert(schedule)
        try ctx.save()

        #expect(schedule.isEnabled == true)
        schedule.fireCount += 1
        schedule.advanceNextFireDate()
        #expect(schedule.isEnabled == false)
    }

    @Test("Skill attachment by ID matches workspace skills")
    func skillAttachment() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/skill-attach")
        ctx.insert(ws)
        let skill = Skill(name: "Test Skill", allowedTools: ["Read"], disallowedTools: [], behaviorInstructions: "")
        skill.workspace = ws
        ctx.insert(skill)
        let schedule = TaskSchedule(name: "Skilled", goal: "G", workspace: ws)
        schedule.skillIDs = [skill.id.uuidString]
        ctx.insert(schedule)
        try ctx.save()

        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)

        let idSet = Set(schedule.skillIDs)
        for s in ws.skills where idSet.contains(s.id.uuidString) {
            task.skills.append(s)
        }

        #expect(task.skills.count == 1)
        #expect(task.skills[0].name == "Test Skill")
    }

    @Test("Schedule skill resolution includes only enabled shared skills")
    func scheduleSharedSkillResolution() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Shared Schedule", primaryPath: "/tmp/shared-schedule")
        ctx.insert(ws)

        let enabledShared = Skill(name: "Enabled Shared", allowedTools: ["Read"])
        enabledShared.isGlobal = true
        ctx.insert(enabledShared)
        ws.enabledGlobalSkillIDs = [enabledShared.id.uuidString]

        let disabledShared = Skill(name: "Disabled Shared", allowedTools: ["Read"])
        disabledShared.isGlobal = true
        ctx.insert(disabledShared)

        let schedule = TaskSchedule(name: "Skilled", goal: "G", workspace: ws)
        schedule.skillIDs = [enabledShared.id.uuidString, disabledShared.id.uuidString]
        ctx.insert(schedule)
        try ctx.save()

        let resolved = TaskScheduler.resolvedSkills(
            for: schedule,
            globalSkills: [enabledShared, disabledShared]
        )

        #expect(resolved.map(\.name) == ["Enabled Shared"])
    }

    @Test("task runtime additional paths include folder inputs")
    func taskRuntimeAdditionalPathsIncludeFolderInputs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-routine-paths-\(UUID().uuidString)", isDirectory: true)
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        let routine = root.appendingPathComponent("routine", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: routine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Paths", primaryPath: root.path, additionalPaths: [extra.path])
        let task = AgentTask(title: "Routine Run", goal: "Run", workspace: workspace)
        task.inputs = [routine.path]

        #expect(TaskWorkspaceAccess(task: task).runtimeAdditionalPaths == [extra.path, routine.path])
    }

    @Test("Due vs future filtering logic")
    func dueFiltering() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let due = TaskSchedule(name: "Due")
        due.isEnabled = true
        due.nextFireDate = Date().addingTimeInterval(-60)
        ctx.insert(due)

        let future = TaskSchedule(name: "Future")
        future.isEnabled = true
        future.nextFireDate = Date().addingTimeInterval(3600)
        ctx.insert(future)

        let disabled = TaskSchedule(name: "Disabled")
        disabled.isEnabled = false
        disabled.nextFireDate = Date().addingTimeInterval(-60)
        ctx.insert(disabled)

        try ctx.save()

        let now = Date()
        let allSchedules = [due, future, disabled]
        let enabled = allSchedules.filter { $0.isEnabled }
        let dueNow = enabled.filter { $0.nextFireDate <= now }

        #expect(dueNow.count == 1)
        #expect(dueNow[0].name == "Due")
    }

    @Test("effectiveGoal with template substitution")
    func templateGoalSubstitution() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/tmpl-fire")
        ctx.insert(ws)
        let template = TaskTemplate(name: "Review", mainGoal: "Review {{file}} in {{mode}} mode", workspace: ws)
        ctx.insert(template)
        let schedule = TaskSchedule(name: "Review", workspace: ws)
        schedule.templateID = template.id
        schedule.templateVariables = ["file": "main.swift", "mode": "strict"]
        ctx.insert(schedule)
        try ctx.save()

        let variables = schedule.templateVariables
        let resolvedGoal = template.resolveGoal(template.mainGoal, with: variables)
        #expect(resolvedGoal.contains("main.swift"))
        #expect(resolvedGoal.contains("strict"))
    }
}
