import Foundation
import SwiftData
import ASTRACore

@Observable @MainActor
final class TaskScheduler {
    private(set) var isRunning = false
    private var checkTask: Task<Void, Never>?

    /// Worst-case re-evaluation interval. Bounds staleness for schedule edits
    /// that don't notify the scheduler — identical to the previous fixed 30s
    /// poll, so there is no idle regression — while letting the loop wake
    /// sooner to fire an imminent schedule on time instead of up to 30s late.
    private static let maxSleepSeconds: TimeInterval = 30
    /// Floor to avoid a hot loop when a schedule is already due or microseconds away.
    private static let minSleepSeconds: TimeInterval = 0.5

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    /// Start the scheduler loop. Call once on app launch.
    @MainActor
    func start(modelContext: ModelContext, taskQueue: TaskQueue) {
        guard !isRunning else { return }
        isRunning = true
        AppLogger.audit(.schedulerStarted, category: "Scheduler")

        checkTask = Task { @MainActor in
            while !Task.isCancelled {
                // One fetch per tick, shared by firing and the sleep
                // computation, so the loop doesn't hit SwiftData twice on the
                // main actor each wake.
                let schedules = fetchEnabledSchedules(modelContext)
                let now = Date()
                fireDueSchedules(schedules, now: now, modelContext: modelContext, taskQueue: taskQueue)
                // fireSchedule advances nextFireDate in place, so the same
                // array already reflects post-fire times here.
                let wait = sleepSeconds(from: schedules, now: now)
                do {
                    try await Task.sleep(for: .seconds(wait))
                } catch { break }
            }
            isRunning = false
        }
    }

    private func fetchEnabledSchedules(_ modelContext: ModelContext) -> [TaskSchedule] {
        let descriptor = FetchDescriptor<TaskSchedule>(
            predicate: #Predicate<TaskSchedule> { $0.isEnabled == true }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fireDueSchedules(
        _ schedules: [TaskSchedule],
        now: Date,
        modelContext: ModelContext,
        taskQueue: TaskQueue
    ) {
        for schedule in schedules where schedule.nextFireDate <= now {
            fireSchedule(schedule, modelContext: modelContext, taskQueue: taskQueue)
        }
    }

    /// Seconds to sleep before the next evaluation: until the soonest future
    /// fire time in `schedules`, clamped to [minSleep, maxSleep]. Falls back to
    /// maxSleep when nothing upcoming is scheduled. Fires imminent schedules on
    /// time without ever polling less often than the old 30s loop.
    private func sleepSeconds(from schedules: [TaskSchedule], now: Date) -> TimeInterval {
        guard let soonest = schedules.map(\.nextFireDate).filter({ $0 > now }).min() else {
            return Self.maxSleepSeconds
        }
        return min(max(soonest.timeIntervalSince(now), Self.minSleepSeconds), Self.maxSleepSeconds)
    }

    /// Convenience wrapper for callers/tests that just want the next sleep
    /// interval; the run loop uses the shared-fetch path above instead.
    @MainActor
    func nextSleepSeconds(modelContext: ModelContext) -> TimeInterval {
        sleepSeconds(from: fetchEnabledSchedules(modelContext), now: Date())
    }

    @MainActor
    func stop() {
        checkTask?.cancel()
        checkTask = nil
        AppLogger.audit(.schedulerStopped, category: "Scheduler")
    }

    @MainActor
    func checkAndFire(modelContext: ModelContext, taskQueue: TaskQueue) {
        fireDueSchedules(
            fetchEnabledSchedules(modelContext),
            now: Date(),
            modelContext: modelContext,
            taskQueue: taskQueue
        )
    }

    @MainActor
    func fireSchedule(_ schedule: TaskSchedule, modelContext: ModelContext, taskQueue: TaskQueue) {
        let task: AgentTask
        let runtime = schedule.resolvedRuntimeID

        if let templateID = schedule.templateID,
           let template = schedule.workspace?.templates.first(where: { $0.id == templateID }) {
            let variables = schedule.templateSubstitutionVariables
            let resolvedGoal = template.resolveGoal(template.mainGoal, with: variables)
            task = AgentTask(
                title: "\(schedule.name) — \(Self.dateFormatter.string(from: Date()))",
                goal: resolvedGoal,
                workspace: schedule.workspace,
                tokenBudget: schedule.tokenBudget,
                model: schedule.model,
                runtime: runtime
            )
        } else {
            task = AgentTask(
                title: "\(schedule.name) — \(Self.dateFormatter.string(from: Date()))",
                goal: schedule.effectiveGoal,
                workspace: schedule.workspace,
                tokenBudget: schedule.tokenBudget,
                model: schedule.model,
                runtime: runtime
            )
        }

        for path in schedule.routinePaths where !task.inputs.contains(path) {
            task.inputs.append(path)
        }

        TaskStateMachine.enqueueFromScheduler(task, modelContext: modelContext)
        task.originScheduleID = schedule.id
        modelContext.insert(task)

        if schedule.workspace != nil {
            let globalDescriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })
            let globals = (try? modelContext.fetch(globalDescriptor)) ?? []
            for skill in Self.resolvedSkills(for: schedule, globalSkills: globals) {
                task.skills.append(skill)
            }
        }

        schedule.lastFiredAt = Date()
        schedule.fireCount += 1
        schedule.advanceNextFireDate()

        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: schedule.workspace, modelContext: modelContext
        )

        AppLogger.audit(.scheduleFired, category: "Scheduler", taskID: task.id, fields: [
            "schedule_id": schedule.id.uuidString,
            "workspace_id": schedule.workspace?.id.uuidString ?? "none"
        ])

        taskQueue.processQueueIfIdle(modelContext: modelContext)
    }

    static func resolvedSkills(for schedule: TaskSchedule, globalSkills: [Skill]) -> [Skill] {
        guard let workspace = schedule.workspace else { return [] }

        let effectiveSkillIDs: [String]
        if !schedule.skillIDs.isEmpty {
            effectiveSkillIDs = schedule.skillIDs
        } else if let templateID = schedule.templateID,
                  let template = workspace.templates.first(where: { $0.id == templateID }),
                  !template.defaultSkillIDs.isEmpty {
            effectiveSkillIDs = template.defaultSkillIDs
        } else {
            effectiveSkillIDs = []
        }

        guard !effectiveSkillIDs.isEmpty else { return [] }

        let idSet = Set(effectiveSkillIDs)
        return WorkspaceCapabilities(workspace: workspace, globalSkills: globalSkills)
            .activeSkills
            .filter { idSet.contains($0.id.uuidString) }
    }
}
