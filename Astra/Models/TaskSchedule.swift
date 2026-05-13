import Foundation
import SwiftData
import ASTRACore

enum ScheduleType: String, Codable, CaseIterable {
    case once
    case interval
    case daily
    case weekly
}

enum ScheduleResultMode: String, Codable, CaseIterable {
    case sameThread = "same_thread"     // Post results back to the source task's conversation
    case newTask = "new_task"           // Each run creates an independent task
    case scheduleLog = "schedule_log"   // Store results in the routine's own run history

    var label: String {
        switch self {
        case .sameThread: return "Same thread"
        case .newTask: return "New task"
        case .scheduleLog: return "Routine log"
        }
    }

    var description: String {
        switch self {
        case .sameThread: return "Post results to the original conversation"
        case .newTask: return "Create a new task for each run"
        case .scheduleLog: return "Store results in the routine's run history"
        }
    }
}

@Model
final class TaskSchedule {
    private static let routineDescriptionKey = "__astra_routine_description"
    private static let routinePathsKey = "__astra_routine_paths_json"
    private static let routineMetadataKeys: Set<String> = [
        routineDescriptionKey,
        routinePathsKey
    ]

    var id: UUID
    var name: String
    var isEnabled: Bool

    // What to run — goal (simple) or template reference (complex)
    var goal: String
    var templateID: UUID?
    var templateVariablesJSON: String

    // Execution defaults
    var runtimeID: String?
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
        runtimeID: String? = TaskExecutionDefaults.runtime.rawValue,
        model: String = TaskExecutionDefaults.model,
        tokenBudget: Int = TaskExecutionDefaults.tokenBudget,
        scheduleType: ScheduleType = .once,
        nextFireDate: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.isEnabled = true
        self.goal = goal
        self.templateVariablesJSON = "{}"
        self.runtimeID = runtimeID
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

    var resolvedRuntimeID: AgentRuntimeID {
        AgentRuntimeID(rawValue: runtimeID ?? "") ?? TaskExecutionDefaults.runtime
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

    var templateSubstitutionVariables: [String: String] {
        templateVariables.filter { !Self.routineMetadataKeys.contains($0.key) }
    }

    var routineDescription: String {
        get { templateVariables[Self.routineDescriptionKey] ?? "" }
        set { setRoutineMetadataValue(newValue, forKey: Self.routineDescriptionKey) }
    }

    var routineInstructions: String {
        get { goal }
        set { goal = newValue }
    }

    var routinePaths: [String] {
        get {
            guard let json = templateVariables[Self.routinePathsKey],
                  let data = json.data(using: .utf8) else {
                return []
            }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            let cleaned = Self.uniqueNonEmptyPaths(newValue)
            guard !cleaned.isEmpty,
                  let data = try? JSONEncoder().encode(cleaned),
                  let json = String(data: data, encoding: .utf8) else {
                setRoutineMetadataValue("", forKey: Self.routinePathsKey)
                return
            }
            setRoutineMetadataValue(json, forKey: Self.routinePathsKey)
        }
    }

    /// The full goal including conversation context, used when firing the schedule.
    var effectiveGoal: String {
        let description = routineDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = routineInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = routinePaths

        if description.isEmpty, paths.isEmpty, conversationContext.isEmpty {
            return goal
        }

        var sections: [String] = []
        if !description.isEmpty {
            sections.append("Routine description:\n\(description)")
        }
        if !instructions.isEmpty {
            sections.append("Routine instructions:\n\(instructions)")
        }
        if !paths.isEmpty {
            sections.append("Routine folders:\n" + paths.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !conversationContext.isEmpty {
            sections.append("""
            Conversation context from when this routine was created:
            \(conversationContext)
            """)
        }
        return sections.joined(separator: "\n\n")
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

    private func setRoutineMetadataValue(_ value: String, forKey key: String) {
        var variables = templateVariables
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            variables.removeValue(forKey: key)
        } else {
            variables[key] = value
        }
        templateVariables = variables
    }

    private static func uniqueNonEmptyPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (trimmed as NSString).isAbsolutePath,
                  !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
