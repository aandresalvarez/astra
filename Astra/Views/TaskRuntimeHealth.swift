import Foundation
import ASTRAModels

enum TaskRuntimeHealthState: String, Equatable, Sendable {
    case notRunning = "not_running"
    case active
    case quiet
    case recoveredWarning = "recovered_warning"
    case possiblyStalled = "possibly_stalled"
}

struct TaskRuntimeHealth: Equatable, Sendable {
    static let quietThreshold: TimeInterval = 5 * 60

    let state: TaskRuntimeHealthState
    let message: String
    let detail: String?
    let lastActivityAt: Date?
    let lastRuntimeProgressAt: Date?
    let lastConversationAt: Date?
    let lastWarningAt: Date?
    let lastWarningTool: String?
    let latestToolName: String?
    let latestRunID: UUID?
    let eventCount: Int
    let outputCharacterCount: Int

    var telemetrySignature: String {
        [
            state.rawValue,
            latestRunID?.uuidString ?? "none",
            lastActivityAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
            lastRuntimeProgressAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
            lastConversationAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
            lastWarningAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
            latestToolName ?? "none",
            String(eventCount),
            String(outputCharacterCount)
        ].joined(separator: "|")
    }

    var isAttentionState: Bool {
        state == .possiblyStalled
    }

    static func evaluate(
        taskStatus: TaskStatus,
        snapshot: TaskThreadSnapshot,
        now: Date = Date(),
        quietThreshold: TimeInterval = Self.quietThreshold
    ) -> TaskRuntimeHealth {
        guard taskStatus == .running, let run = snapshot.latestRun else {
            return TaskRuntimeHealth(
                state: .notRunning,
                message: "",
                detail: nil,
                lastActivityAt: nil,
                lastRuntimeProgressAt: nil,
                lastConversationAt: nil,
                lastWarningAt: nil,
                lastWarningTool: nil,
                latestToolName: nil,
                latestRunID: snapshot.latestRun?.id,
                eventCount: snapshot.sortedEvents.count,
                outputCharacterCount: snapshot.latestRun?.output.count ?? 0
            )
        }

        let runEvents = snapshot.sortedEvents
            .filter { $0.runID == nil || $0.runID == run.id }
            .sorted { $0.timestamp < $1.timestamp }
        let fileActivity = snapshot.activity(for: run).fileChanges.max { $0.timestamp < $1.timestamp }
        let progressEvents = runEvents.filter(Self.isProgressEvent)
        let latestProgressEvent = progressEvents.last
        let latestProgressAt = latestDate(latestProgressEvent?.timestamp, fileActivity?.timestamp)
        let latestConversationAt = runEvents.last(where: Self.isConversationActivityEvent)?.timestamp
        let latestWarning = runEvents.last { $0.type == "permission.denied" }
        let latestPlanBlock = runEvents.last { $0.type == "plan.step.blocked" }
        let laterProgressAfterWarningAt = latestWarning.flatMap { warning -> Date? in
            let laterEventAt = progressEvents.last { $0.timestamp > warning.timestamp }?.timestamp
            let laterFileAt = fileActivity.flatMap { $0.timestamp > warning.timestamp ? $0.timestamp : nil }
            return latestDate(laterEventAt, laterFileAt)
        }
        let laterProgressAfterPlanBlockAt = latestPlanBlock.flatMap { block -> Date? in
            let laterEventAt = progressEvents.last { $0.timestamp > block.timestamp }?.timestamp
            let laterFileAt = fileActivity.flatMap { $0.timestamp > block.timestamp ? $0.timestamp : nil }
            return latestDate(laterEventAt, laterFileAt)
        }

        let lastActivityAt = latestDate(
            latestProgressAt,
            latestDate(latestConversationAt, latestDate(latestWarning?.timestamp, latestPlanBlock?.timestamp))
        ) ?? run.startedAt
        let secondsSinceProgress = latestProgressAt.map { now.timeIntervalSince($0) } ?? now.timeIntervalSince(run.startedAt)
        let secondsSinceWarning = latestWarning.map { now.timeIntervalSince($0.timestamp) }
        let secondsSincePlanBlock = latestPlanBlock.map { now.timeIntervalSince($0.timestamp) }
        let latestTool = latestToolName(from: runEvents)
        let warningTool = latestWarning.flatMap(permissionToolName)
        let blockedStep = latestPlanBlock.flatMap(planStepID)

        let state: TaskRuntimeHealthState
        if latestPlanBlock != nil,
           laterProgressAfterPlanBlockAt == nil,
           (secondsSincePlanBlock ?? 0) >= quietThreshold {
            state = .possiblyStalled
        } else if latestWarning != nil, laterProgressAfterWarningAt == nil, (secondsSinceWarning ?? 0) >= quietThreshold {
            state = .possiblyStalled
        } else if latestWarning != nil,
                  laterProgressAfterWarningAt != nil,
                  let latestProgressAt,
                  now.timeIntervalSince(latestProgressAt) < quietThreshold {
            state = .recoveredWarning
        } else if secondsSinceProgress >= quietThreshold {
            state = .quiet
        } else {
            state = .active
        }

        let message = message(
            state: state,
            latestProgressEvent: latestProgressEvent,
            latestTool: latestTool,
            fileActivity: fileActivity,
            now: now,
            lastActivityAt: lastActivityAt,
            latestRuntimeProgressAt: latestProgressAt,
            latestConversationAt: latestConversationAt,
            quietThreshold: quietThreshold,
            warningTool: warningTool,
            blockedStep: blockedStep
        )
        let detail = detail(
            state: state,
            now: now,
            lastActivityAt: lastActivityAt,
            latestRuntimeProgressAt: latestProgressAt,
            latestConversationAt: latestConversationAt,
            quietThreshold: quietThreshold,
            latestWarning: latestWarning,
            latestPlanBlock: latestPlanBlock
        )

        return TaskRuntimeHealth(
            state: state,
            message: message,
            detail: detail,
            lastActivityAt: lastActivityAt,
            lastRuntimeProgressAt: latestProgressAt,
            lastConversationAt: latestConversationAt,
            lastWarningAt: latestWarning?.timestamp,
            lastWarningTool: warningTool,
            latestToolName: latestTool,
            latestRunID: run.id,
            eventCount: snapshot.sortedEvents.count,
            outputCharacterCount: run.output.count
        )
    }

    func telemetryFields(reason: String) -> [String: String] {
        var fields: [String: String] = [
            "reason": reason,
            "state": state.rawValue,
            "event_count": String(eventCount),
            "output_chars": String(outputCharacterCount),
            "run_id": latestRunID?.uuidString.prefix(8).description ?? "none",
            "last_activity_age_seconds": lastActivityAt.map { String(max(0, Int(Date().timeIntervalSince($0)))) } ?? "unknown"
        ]
        if let lastRuntimeProgressAt {
            fields["last_runtime_progress_age_seconds"] = String(max(0, Int(Date().timeIntervalSince(lastRuntimeProgressAt))))
        }
        if let lastConversationAt {
            fields["last_conversation_age_seconds"] = String(max(0, Int(Date().timeIntervalSince(lastConversationAt))))
        }
        if let latestToolName {
            fields["latest_tool"] = latestToolName
        }
        if let lastWarningTool {
            fields["warning_tool"] = lastWarningTool
        }
        if let lastWarningAt {
            fields["last_warning_age_seconds"] = String(max(0, Int(Date().timeIntervalSince(lastWarningAt))))
        }
        return fields
    }

    private static func isProgressEvent(_ event: TaskEventSnapshot) -> Bool {
        switch event.type {
        case "task.started", "agent.response", "agent.thinking", "tool.use", "tool.result",
             "task.stats", "task.completed", "astra.todo.replace", "astra.complete",
             "budget.warning",
             "plan.step.started", "plan.step.completed", "plan.step.blocked", "plan.step.skipped",
             "plan.execution.started", "plan.execution.completed", "plan.execution.failed":
            return true
        default:
            return false
        }
    }

    private static func isConversationActivityEvent(_ event: TaskEventSnapshot) -> Bool {
        switch event.type {
        case "user.message", "task.resumed":
            return true
        default:
            return false
        }
    }

    private static func latestDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none): nil
        case (.some(let date), .none), (.none, .some(let date)): date
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        }
    }

    private static func latestToolName(from events: [TaskEventSnapshot]) -> String? {
        events.last(where: { $0.type == "tool.use" }).flatMap { event in
            toolName(fromToolPayload: event.payload)
        }
    }

    private static func toolName(fromToolPayload payload: String) -> String? {
        let trimmed = payload.replacingOccurrences(of: "Using tool: ", with: "")
        let name = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? trimmed
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func permissionToolName(from event: TaskEventSnapshot) -> String? {
        let marker = "tool:"
        guard let range = event.payload.range(of: marker, options: .caseInsensitive) else {
            return nil
        }
        let remainder = event.payload[range.upperBound...]
        let name = remainder.split(separator: ".").first.map(String.init) ?? String(remainder)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "unknown" ? nil : clean
    }

    private static func planStepID(from event: TaskEventSnapshot) -> String? {
        guard let data = event.payload.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stepID = decoded["stepID"] as? String else {
            return nil
        }
        let clean = stepID.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func message(
        state: TaskRuntimeHealthState,
        latestProgressEvent: TaskEventSnapshot?,
        latestTool: String?,
        fileActivity: StoredFileChange?,
        now: Date,
        lastActivityAt: Date,
        latestRuntimeProgressAt: Date?,
        latestConversationAt: Date?,
        quietThreshold: TimeInterval,
        warningTool: String?,
        blockedStep: String?
    ) -> String {
        let waitingForResponse = isWaitingForAgentResponse(
            latestRuntimeProgressAt: latestRuntimeProgressAt,
            latestConversationAt: latestConversationAt
        )
        switch state {
        case .notRunning:
            return ""
        case .possiblyStalled:
            if let blockedStep {
                return "Plan step \(blockedStep) is blocked"
            }
            if let warningTool {
                return "Possibly waiting after \(warningTool) permission warning"
            }
            return "Possibly waiting after a permission warning"
        case .quiet:
            if waitingForResponse {
                if let latestConversationAt,
                   now.timeIntervalSince(latestConversationAt) < quietThreshold {
                    return "Waiting for agent response..."
                }
                return "Still waiting for agent output"
            }
            if latestRuntimeProgressAt != nil {
                return "Still running; no new agent output recently"
            }
            return "Still running; waiting for first agent output"
        case .recoveredWarning:
            if let warningTool {
                return "Permission warning recovered for \(warningTool)"
            }
            return "Permission warning recovered"
        case .active:
            if waitingForResponse {
                return "Waiting for agent response..."
            }
            if let fileActivity,
               fileActivity.timestamp >= (latestProgressEvent?.timestamp ?? .distantPast) {
                return "Updating files..."
            }
            if let event = latestProgressEvent {
                switch event.type {
                case "plan.step.started":
                    return "Working on a plan step..."
                case "plan.step.completed":
                    return "Plan step completed..."
                case "plan.step.blocked":
                    if let blockedStep {
                        return "Plan step \(blockedStep) is blocked"
                    }
                    return "Plan step is blocked"
                case "plan.step.skipped":
                    return "Skipping a plan step..."
                case "tool.use":
                    return latestTool.map { "Running \($0)..." } ?? "Running a tool..."
                case "tool.result":
                    return "Processing tool output..."
                case "agent.response":
                    return "Writing response..."
                case "agent.thinking":
                    return "Thinking..."
                case "task.stats":
                    return "Updating run statistics..."
                case "task.completed", "astra.complete":
                    return "Finishing run..."
                default:
                    break
                }
            }
            return "Agent is working..."
        }
    }

    private static func detail(
        state: TaskRuntimeHealthState,
        now: Date,
        lastActivityAt: Date,
        latestRuntimeProgressAt: Date?,
        latestConversationAt: Date?,
        quietThreshold: TimeInterval,
        latestWarning: TaskEventSnapshot?,
        latestPlanBlock: TaskEventSnapshot?
    ) -> String? {
        let waitingForResponse = isWaitingForAgentResponse(
            latestRuntimeProgressAt: latestRuntimeProgressAt,
            latestConversationAt: latestConversationAt
        )
        switch state {
        case .notRunning:
            return nil
        case .possiblyStalled:
            if let latestPlanBlock {
                return "No new plan progress, agent output, tool results, or file changes for \(relativeAge(from: latestPlanBlock.timestamp, to: now)) after the blocker."
            }
            return "No new agent output, tool results, or file changes for \(relativeAge(from: latestWarning?.timestamp ?? lastActivityAt, to: now)) after the warning."
        case .quiet:
            if waitingForResponse, let latestConversationAt {
                if now.timeIntervalSince(latestConversationAt) < quietThreshold {
                    return "Your last message was \(relativeAge(from: latestConversationAt, to: now)) ago. ASTRA has not seen agent output for this follow-up yet."
                }
                return "Your last message was \(relativeAge(from: latestConversationAt, to: now)) ago. ASTRA has not seen agent output, tool results, or file changes for this follow-up."
            }
            if let latestRuntimeProgressAt {
                return "Last agent progress was \(relativeAge(from: latestRuntimeProgressAt, to: now)) ago. ASTRA has not seen new output, tool results, or file changes recently."
            }
            return "ASTRA has not seen agent output, tool results, or file changes for this run yet."
        case .recoveredWarning:
            return "The task produced progress after the warning."
        case .active:
            if waitingForResponse, let latestConversationAt {
                return "Your last message was \(relativeAge(from: latestConversationAt, to: now)) ago. ASTRA is waiting for the first agent output."
            }
            return nil
        }
    }

    private static func isWaitingForAgentResponse(
        latestRuntimeProgressAt: Date?,
        latestConversationAt: Date?
    ) -> Bool {
        guard let latestConversationAt else {
            return false
        }
        guard let latestRuntimeProgressAt else {
            return true
        }
        return latestConversationAt > latestRuntimeProgressAt
    }

    private static func relativeAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        return "\(hours)h"
    }
}
