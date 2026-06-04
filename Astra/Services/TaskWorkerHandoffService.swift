import Foundation
import SwiftData

@MainActor
enum TaskWorkerHandoffService {
    @discardableResult
    static func recordCreatedIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        discoveredFiles: [TaskOutputDiscoveredFile]? = nil
    ) -> TaskEvent? {
        if task.events.contains(where: { $0.type == TaskHandoffEventTypes.created && $0.run?.id == run.id }) {
            return nil
        }

        let payload = makePayload(task: task, run: run, discoveredFiles: discoveredFiles)
        let event = TaskEvent(task: task, type: TaskHandoffEventTypes.created, payload: encode(payload), run: run)
        modelContext.insert(event)
        AppLogger.audit(.handoffCreated, category: "Worker", taskID: task.id, fields: [
            "run_id": run.id.uuidString,
            "task_status": task.status.rawValue,
            "run_status": run.status.rawValue,
            "completed_count": String(payload.completedWork.count),
            "unfinished_count": String(payload.unfinishedWork.count),
            "command_count": String(payload.commands.count),
            "file_count": String(payload.filesChanged.count),
            "blocker_count": String(payload.blockers.count)
        ])
        TaskContextStateManager.refresh(task: task)
        return event
    }

    static func decode(_ payload: String) -> TaskWorkerHandoffPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskWorkerHandoffPayload.self, from: data)
    }

    private static func makePayload(
        task: AgentTask,
        run: TaskRun,
        discoveredFiles: [TaskOutputDiscoveredFile]?
    ) -> TaskWorkerHandoffPayload {
        let runEvents = task.events.filter { $0.run?.id == run.id }
        let completedWork = completedWorkFacts(task: task, run: run, runEvents: runEvents)
        let unfinishedWork = unfinishedWorkFacts(task: task)
        let blockers = blockerFacts(run: run, runEvents: runEvents)
        let validationEvidence = runEvents
            .filter { $0.type.hasPrefix("validation.") }
            .map { "\($0.type): \(boundedInline($0.payload, maxCharacters: 220))" }
        let discoveredFiles = discoveredFiles ?? TaskOutputDiscovery.files(for: task)
        let discoveredRunFiles = TaskOutputDiscovery.filesChanged(during: run, from: discoveredFiles).map(\.path)
        let filesChanged = dedupe(run.fileChanges.map(\.path) + discoveredRunFiles, limit: 50)
        let artifactsCreated = dedupe(task.artifacts.map(\.path) + discoveredFiles.map(\.path), limit: 30)
        let commands = runEvents
            .filter { $0.type == "tool.use" }
            .prefix(12)
            .map {
                TaskWorkerHandoffPayload.Command(
                    summary: boundedInline($0.payload, maxCharacters: 220),
                    exitCode: run.exitCode
                )
            }
        let risks = riskFacts(task: task, run: run, blockers: blockers)

        return TaskWorkerHandoffPayload(
            version: 1,
            runID: run.id,
            taskStatus: task.status.rawValue,
            runStatus: run.status.rawValue,
            completedWork: completedWork,
            unfinishedWork: unfinishedWork,
            commands: Array(commands),
            filesChanged: filesChanged,
            artifactsCreated: artifactsCreated,
            validationEvidence: Array(validationEvidence.prefix(12)),
            blockers: blockers,
            risks: risks,
            suggestedNextAction: suggestedNextAction(task: task, blockers: blockers, unfinishedWork: unfinishedWork),
            createdAt: isoTimestamp(Date())
        )
    }

    private static func completedWorkFacts(
        task: AgentTask,
        run: TaskRun,
        runEvents: [TaskEvent]
    ) -> [String] {
        var facts = runEvents
            .filter { $0.type == TaskPlanEventTypes.stepCompleted }
            .compactMap { TaskPlanService.decodeStepProgressPayload($0.payload)?.summary }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let visibleOutput = run.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !visibleOutput.isEmpty {
            facts.append(boundedInline(visibleOutput, maxCharacters: 420))
        }
        if facts.isEmpty, task.status == .completed {
            facts.append("Task completed.")
        }
        return dedupe(facts, limit: 12)
    }

    private static func unfinishedWorkFacts(task: AgentTask) -> [String] {
        let planState = TaskPlanService.reconstruct(for: task)
        let unfinished = planState.plan?.steps.compactMap { step -> String? in
            switch step.status {
            case .pending, .running, .blocked:
                return "\(step.status.rawValue): \(step.title)"
            case .done, .skipped:
                return nil
            }
        } ?? []
        return dedupe(unfinished, limit: 12)
    }

    private static func blockerFacts(run: TaskRun, runEvents: [TaskEvent]) -> [String] {
        let planBlockers = runEvents
            .filter { $0.type == TaskPlanEventTypes.stepBlocked }
            .compactMap { event -> String? in
                guard let payload = TaskPlanService.decodeStepProgressPayload(event.payload) else {
                    return "plan.step.blocked: \(boundedInline(event.payload, maxCharacters: 260))"
                }
                let reason = [
                    payload.reason,
                    payload.detail,
                    payload.summary
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "No reason recorded"
                return "Plan step blocked: \(payload.stepID) - \(boundedInline(reason, maxCharacters: 220))"
            }
        let eventBlockers = runEvents
            .filter {
                ["error", "permission.denied", "permission.approval.requested", "budget.exceeded"].contains($0.type) ||
                    $0.type == TaskValidationEventTypes.contractFailed
            }
            .map { "\($0.type): \(boundedInline($0.payload, maxCharacters: 260))" }
        let stopReason = run.stopReason.trimmingCharacters(in: .whitespacesAndNewlines)
        return dedupe(
            (stopReason.isEmpty || stopReason == "completed" ? [] : ["Run stopped: \(stopReason)"]) +
                planBlockers +
                eventBlockers,
            limit: 12
        )
    }

    private static func riskFacts(task: AgentTask, run: TaskRun, blockers: [String]) -> [String] {
        var risks: [String] = []
        if !blockers.isEmpty {
            risks.append("Open blockers remain before this work can be trusted as complete.")
        }
        if task.status == .pendingUser {
            risks.append("Human review or approval is required before continuing.")
        }
        if run.status == .failed || task.status == .failed {
            risks.append("Latest run failed and should be repaired or retried.")
        }
        return dedupe(risks, limit: 8)
    }

    private static func suggestedNextAction(
        task: AgentTask,
        blockers: [String],
        unfinishedWork: [String]
    ) -> String? {
        if !blockers.isEmpty {
            return "Resolve the blocker, then rerun the failed validation or continue the approved plan."
        }
        if let next = unfinishedWork.first {
            return "Continue with \(next)."
        }
        if task.status == .completed {
            return "Review the result and mark the task done if no follow-up is needed."
        }
        return nil
    }

    private static func boundedInline(_ value: String, maxCharacters: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + "..."
    }

    private static func dedupe(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count >= limit { break }
        }
        return result
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func encode<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
