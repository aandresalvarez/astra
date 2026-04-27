import Foundation
import SwiftData

enum ScheduleType: String, Codable, CaseIterable {
    case once
    case interval
    case daily
    case weekly
}

enum ScheduleResultMode: String, Codable, CaseIterable {
    case sameThread = "same_thread"     // Post results back to the source task's conversation
    case newTask = "new_task"           // Each run creates an independent task
    case scheduleLog = "schedule_log"   // Store results in the schedule's own run history

    var label: String {
        switch self {
        case .sameThread: return "Same thread"
        case .newTask: return "New task"
        case .scheduleLog: return "Schedule log"
        }
    }

    var description: String {
        switch self {
        case .sameThread: return "Post results to the original conversation"
        case .newTask: return "Create a new task for each run"
        case .scheduleLog: return "Store results in the schedule's run history"
        }
    }
}

@Model
final class TaskSchedule {
    var id: UUID
    var name: String
    var isEnabled: Bool

    // What to run — goal (simple) or template reference (complex)
    var goal: String
    var templateID: UUID?
    var templateVariablesJSON: String

    // Execution defaults
    var model: String
    var tokenBudget: Int
    var skillIDs: [String]  // UUIDs of skills to attach to created tasks

    // Schedule configuration
    var scheduleType: ScheduleType
    var nextFireDate: Date
    var intervalSeconds: Int      // For .interval (e.g. 3600 = hourly)
    var dailyHour: Int            // For .daily/.weekly (0-23)
    var dailyMinute: Int          // For .daily/.weekly (0-59)
    var weeklyDayOfWeek: Int      // For .weekly (1=Sun..7=Sat)

    // Conversation context snapshot (captured at schedule creation time)
    var conversationContext: String

    // Result routing
    var resultMode: ScheduleResultMode
    var sourceTaskID: UUID?          // Task this schedule was created from (for sameThread mode)
    var runResultsJSON: String       // JSON array of run results (for scheduleLog mode)

    // Audit
    var lastFiredAt: Date?
    var fireCount: Int

    // Ownership
    var workspace: Workspace?

    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        goal: String = "",
        workspace: Workspace? = nil,
        model: String = "claude-sonnet-4-6",
        tokenBudget: Int = 50000,
        scheduleType: ScheduleType = .once,
        nextFireDate: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.isEnabled = true
        self.goal = goal
        self.templateVariablesJSON = "{}"
        self.model = model
        self.tokenBudget = tokenBudget
        self.skillIDs = []
        self.scheduleType = scheduleType
        self.nextFireDate = nextFireDate
        self.intervalSeconds = 3600
        self.dailyHour = 9
        self.dailyMinute = 0
        self.weeklyDayOfWeek = 2 // Monday
        self.conversationContext = ""
        self.resultMode = .sameThread
        self.runResultsJSON = "[]"
        self.fireCount = 0
        self.workspace = workspace
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Advances nextFireDate based on scheduleType. For .once, disables the schedule.
    func advanceNextFireDate() {
        let now = Date()
        switch scheduleType {
        case .once:
            isEnabled = false
        case .interval:
            nextFireDate = now.addingTimeInterval(TimeInterval(intervalSeconds))
        case .daily:
            nextFireDate = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: dailyHour, minute: dailyMinute),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(86400)
        case .weekly:
            nextFireDate = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: dailyHour, minute: dailyMinute, weekday: weeklyDayOfWeek),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(604800)
        }
        updatedAt = now
    }

    var templateVariables: [String: String] {
        get {
            guard let data = templateVariablesJSON.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else { return }
            templateVariablesJSON = json
        }
    }

    /// The full goal including conversation context, used when firing the schedule.
    var effectiveGoal: String {
        if conversationContext.isEmpty {
            return goal
        }
        return """
        \(goal)

        --- Conversation context from when this schedule was created ---
        \(conversationContext)
        """
    }

    /// Human-readable summary of the schedule frequency
    var frequencySummary: String {
        switch scheduleType {
        case .once:
            return "Once"
        case .interval:
            if intervalSeconds < 3600 {
                return "Every \(intervalSeconds / 60)m"
            } else if intervalSeconds == 3600 {
                return "Hourly"
            } else {
                return "Every \(intervalSeconds / 3600)h"
            }
        case .daily:
            return "Daily at \(String(format: "%02d:%02d", dailyHour, dailyMinute))"
        case .weekly:
            let days = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let day = weeklyDayOfWeek >= 1 && weeklyDayOfWeek <= 7 ? days[weeklyDayOfWeek] : "?"
            return "\(day) at \(String(format: "%02d:%02d", dailyHour, dailyMinute))"
        }
    }

    // MARK: - Run Results (for scheduleLog mode)

    struct RunResult: Codable {
        var date: Date
        var status: String       // "completed", "failed", etc.
        var summary: String      // First ~500 chars of output
        var taskID: String       // ID of the spawned task
    }

    var runResults: [RunResult] {
        get {
            guard let data = runResultsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([RunResult].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else { return }
            runResultsJSON = json
        }
    }

    func appendRunResult(status: String, summary: String, taskID: UUID) {
        var results = runResults
        results.append(RunResult(date: Date(), status: status, summary: summary, taskID: taskID.uuidString))
        // Keep last 50 results
        if results.count > 50 { results = Array(results.suffix(50)) }
        runResults = results
    }
}
