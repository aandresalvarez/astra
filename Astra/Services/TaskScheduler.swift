import Foundation
import SwiftData
import ASTRACore

@Observable @MainActor
final class TaskScheduler {
    private(set) var isRunning = false
    private var checkTask: Task<Void, Never>?

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
                checkAndFire(modelContext: modelContext, taskQueue: taskQueue)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch { break }
            }
            isRunning = false
        }
    }

    @MainActor
    func stop() {
        checkTask?.cancel()
        checkTask = nil
        AppLogger.audit(.schedulerStopped, category: "Scheduler")
    }

    @MainActor
    func checkAndFire(modelContext: ModelContext, taskQueue: TaskQueue) {
        let now = Date()
        let descriptor = FetchDescriptor<TaskSchedule>(
            predicate: #Predicate<TaskSchedule> { $0.isEnabled == true }
        )

        guard let schedules = try? modelContext.fetch(descriptor) else { return }
        let due = schedules.filter { $0.nextFireDate <= now }
        guard !due.isEmpty else { return }

        for schedule in due {
            fireSchedule(schedule, modelContext: modelContext, taskQueue: taskQueue)
        }
    }

    @MainActor
    func fireSchedule(_ schedule: TaskSchedule, modelContext: ModelContext, taskQueue: TaskQueue) {
        let task: AgentTask

        if let templateID = schedule.templateID,
           let template = schedule.workspace?.templates.first(where: { $0.id == templateID }) {
            let variables = schedule.templateSubstitutionVariables
            let resolvedGoal = template.resolveGoal(template.mainGoal, with: variables)
            task = AgentTask(
                title: "\(schedule.name) — \(Self.dateFormatter.string(from: Date()))",
                goal: resolvedGoal,
                workspace: schedule.workspace,
                tokenBudget: schedule.tokenBudget,
                model: schedule.model
            )
        } else {
            task = AgentTask(
                title: "\(schedule.name) — \(Self.dateFormatter.string(from: Date()))",
                goal: schedule.effectiveGoal,
                workspace: schedule.workspace,
                tokenBudget: schedule.tokenBudget,
                model: schedule.model
            )
        }

        for path in schedule.routinePaths where !task.inputs.contains(path) {
            task.inputs.append(path)
        }

        task.runtimeID = schedule.resolvedRuntimeID.rawValue
        task.status = .queued
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

        // Always trigger queue processing for scheduled tasks.
        // If the queue is already processing, it will pick up the new task in its loop.
        // If not, we start a new processing cycle.
        let queue = taskQueue
        let ctx = modelContext
        Task { @MainActor in
            if queue.isProcessing {
                // Queue loop is active — it polls for queued tasks, so just ensure
                // the task gets picked up by executing it directly if a worker is free
                if queue.hasAvailableWorker {
                    await queue.executeTask(task, modelContext: ctx)
                }
                // Otherwise the loop will find it on next iteration
            } else {
                await queue.processQueue(modelContext: ctx)
            }
        }
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
