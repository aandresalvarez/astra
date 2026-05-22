import Foundation
import SwiftData
import ASTRACore

enum TaskPlanEventTypes {
    static let created = "plan.created"
    static let updated = "plan.updated"
    static let approved = "plan.approved"
    static let cancelled = "plan.cancelled"
    static let executionStarted = "plan.execution.started"
    static let executionCompleted = "plan.execution.completed"
    static let executionFailed = "plan.execution.failed"
    static let userMessage = "plan.user.message"
    static let assistantMessage = "plan.assistant.message"

    static let stepStarted = "plan.step.started"
    static let stepCompleted = "plan.step.completed"
    static let stepBlocked = "plan.step.blocked"
    static let stepSkipped = "plan.step.skipped"

    static let stepEvents: Set<String> = [
        stepStarted,
        stepCompleted,
        stepBlocked,
        stepSkipped
    ]
}

typealias TaskPlanEventType = TaskPlanEventTypes

enum TaskPlanConversationEventTypes {
    static let userMessage = TaskPlanEventTypes.userMessage
    static let assistantMessage = TaskPlanEventTypes.assistantMessage
}

enum TaskPlanFallbackBuilder {
    static func plan(from responseText: String, fallbackGoal: String) -> TaskPlanPayload {
        TaskPlanService.parsePlan(from: responseText, fallbackGoal: fallbackGoal)
    }
}

enum TaskPlanService {
    static func currentState(for task: AgentTask) -> TaskPlanState {
        reconstruct(for: task)
    }

    static func parsePlan(from responseText: String, fallbackGoal: String) -> TaskPlanPayload {
        parsePlanPayload(from: responseText) ?? fallbackPlan(from: responseText, fallbackGoal: fallbackGoal)
    }

    static func parsePlanPayload(from responseText: String) -> TaskPlanPayload? {
        for candidate in jsonCandidates(in: responseText) {
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(TaskPlanPayload.self, from: data),
                  let normalized = normalize(decoded) else {
                continue
            }
            return normalized
        }
        return nil
    }

    static func userVisiblePlanningText(from responseText: String) -> String {
        var result = stripAstraPlanLines(from: responseText)
        result = stripFencedPlanJSON(from: result)
        result = stripStandalonePlanJSONLines(from: result)
        result = normalizeVisiblePlanningText(result)

        if result.isEmpty {
            return "I prepared a plan. Review it in the Plan panel, then run it when you're ready."
        }
        return result
    }

    static func encodePlanPayload(_ plan: TaskPlanPayload) -> String {
        encode(normalize(plan) ?? plan)
    }

    static func encodeStepProgressPayload(_ payload: TaskPlanProgressPayload) -> String {
        encode(payload)
    }

    static func reconstruct(for task: AgentTask) -> TaskPlanState {
        var state = reconstruct(from: task.events)
        applyRecoveredProtocolProgress(from: task.runs, to: &state)
        return state
    }

    static func reconstruct(from events: [TaskEvent]) -> TaskPlanState {
        var state = TaskPlanState.empty

        for event in sortedEventsForReconstruction(events) {
            state.latestEventAt = event.timestamp

            switch event.type {
            case TaskPlanEventTypes.created:
                guard let plan = decodePlanPayload(event.payload) else { continue }
                state.plan = plan
                state.lifecycleStatus = .draft
                state.approvedAt = nil
                state.cancelledAt = nil
                state.cancellationReason = nil
                state.executionStartedAt = nil
                state.executionCompletedAt = nil
                state.executionFailedAt = nil

            case TaskPlanEventTypes.updated:
                guard let plan = decodePlanPayload(event.payload) else { continue }
                state.plan = mergeHistoricalStepState(from: state.plan, into: plan)
                if [.none, .cancelled, .completed, .failed].contains(state.lifecycleStatus) {
                    state.lifecycleStatus = .draft
                }

            case TaskPlanEventTypes.approved:
                guard let plan = decodePlanPayload(event.payload) else { continue }
                state.plan = mergeHistoricalStepState(from: state.plan, into: plan)
                state.lifecycleStatus = .approved
                state.approvedAt = event.timestamp
                state.cancelledAt = nil
                state.cancellationReason = nil
                state.executionFailedAt = nil

            case TaskPlanEventTypes.cancelled:
                guard matchesCurrentPlan(event.payload, state: state) else { continue }
                state.lifecycleStatus = .cancelled
                state.cancelledAt = event.timestamp
                state.cancellationReason = decodeLifecyclePayload(event.payload)?.reason
                    ?? event.payload.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            case TaskPlanEventTypes.executionStarted:
                guard matchesCurrentPlan(event.payload, state: state) else { continue }
                state.lifecycleStatus = .executing
                state.executionStartedAt = event.timestamp

            case TaskPlanEventTypes.executionCompleted:
                guard matchesCurrentPlan(event.payload, state: state) else { continue }
                state.lifecycleStatus = .completed
                state.executionCompletedAt = event.timestamp

            case TaskPlanEventTypes.executionFailed:
                guard matchesCurrentPlan(event.payload, state: state) else { continue }
                state.lifecycleStatus = .failed
                state.executionFailedAt = event.timestamp
                state.cancellationReason = decodeLifecyclePayload(event.payload)?.reason
                    ?? event.payload.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            case let type where TaskPlanEventTypes.stepEvents.contains(type):
                guard let progress = decodeStepProgressPayload(event.payload) else { continue }
                apply(progress: progress, to: &state)

            default:
                continue
            }
        }

        return state
    }

    private static func sortedEventsForReconstruction(_ events: [TaskEvent]) -> [TaskEvent] {
        events.enumerated()
            .sorted { lhs, rhs in
                let timestampOrder = lhs.element.timestamp.compare(rhs.element.timestamp)
                if timestampOrder != .orderedSame {
                    return timestampOrder == .orderedAscending
                }

                let lhsPriority = reconstructionPriority(for: lhs.element.type)
                let rhsPriority = reconstructionPriority(for: rhs.element.type)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func reconstructionPriority(for eventType: String) -> Int {
        switch eventType {
        case TaskPlanEventTypes.created: 0
        case TaskPlanEventTypes.updated: 1
        case TaskPlanEventTypes.approved: 2
        case TaskPlanEventTypes.executionStarted: 3
        case TaskPlanEventTypes.stepStarted: 4
        case TaskPlanEventTypes.stepCompleted: 5
        case TaskPlanEventTypes.stepBlocked: 6
        case TaskPlanEventTypes.stepSkipped: 7
        case TaskPlanEventTypes.executionCompleted: 8
        case TaskPlanEventTypes.executionFailed: 9
        case TaskPlanEventTypes.cancelled: 10
        default: 20
        }
    }

    static func approvedPlan(for task: AgentTask) -> TaskPlanPayload? {
        let state = reconstruct(for: task)
        switch state.lifecycleStatus {
        case .approved, .executing:
            return state.plan
        case .none, .draft, .completed, .failed, .cancelled:
            return nil
        }
    }

    static func nextExecutableStep(in plan: TaskPlanPayload) -> TaskPlanPayloadStep? {
        plan.steps.first { step in
            switch step.status {
            case .pending, .running, .blocked:
                true
            case .done, .skipped:
                false
            }
        }
    }

    static func hasRemainingExecutableSteps(in plan: TaskPlanPayload) -> Bool {
        nextExecutableStep(in: plan) != nil
    }

    static func isEditablePlanStep(_ step: TaskPlanPayloadStep) -> Bool {
        switch step.status {
        case .pending, .blocked:
            true
        case .running, .done, .skipped:
            false
        }
    }

    static func editableStepCount(in plan: TaskPlanPayload) -> Int {
        plan.steps.filter(isEditablePlanStep).count
    }

    static func makeUniqueStepID(in plan: TaskPlanPayload, preferredTitle: String = "step") -> String {
        let existingIDs = Set(plan.steps.map(\.id))
        let base = slug(for: preferredTitle).isEmpty ? "step" : slug(for: preferredTitle)
        if !existingIDs.contains(base) {
            return base
        }

        var index = 2
        while existingIDs.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }

    @MainActor
    @discardableResult
    static func recordCreated(_ plan: TaskPlanPayload, task: AgentTask, modelContext: ModelContext) -> TaskEvent {
        recordPlanEvent(type: TaskPlanEventTypes.created, plan: plan, task: task, modelContext: modelContext)
    }

    @MainActor
    @discardableResult
    static func recordUpdated(_ plan: TaskPlanPayload, task: AgentTask, modelContext: ModelContext) -> TaskEvent {
        recordPlanEvent(type: TaskPlanEventTypes.updated, plan: plan, task: task, modelContext: modelContext)
    }

    @MainActor
    @discardableResult
    static func recordApproved(_ plan: TaskPlanPayload, task: AgentTask, modelContext: ModelContext) -> TaskEvent {
        recordPlanEvent(type: TaskPlanEventTypes.approved, plan: plan, task: task, modelContext: modelContext)
    }

    @MainActor
    @discardableResult
    static func recordCancelled(planID: UUID, task: AgentTask, modelContext: ModelContext, reason: String? = nil) -> TaskEvent {
        let payload = TaskPlanLifecyclePayload(planID: planID, reason: reason)
        return recordLifecycleEvent(type: TaskPlanEventTypes.cancelled, payload: payload, task: task, modelContext: modelContext)
    }

    @MainActor
    @discardableResult
    static func recordExecutionStarted(planID: UUID, task: AgentTask, modelContext: ModelContext, run: TaskRun? = nil) -> TaskEvent {
        let payload = TaskPlanLifecyclePayload(planID: planID)
        return recordLifecycleEvent(type: TaskPlanEventTypes.executionStarted, payload: payload, task: task, modelContext: modelContext, run: run)
    }

    @MainActor
    @discardableResult
    static func recordExecutionCompleted(planID: UUID, task: AgentTask, modelContext: ModelContext, run: TaskRun? = nil) -> TaskEvent {
        let payload = TaskPlanLifecyclePayload(planID: planID)
        return recordLifecycleEvent(type: TaskPlanEventTypes.executionCompleted, payload: payload, task: task, modelContext: modelContext, run: run)
    }

    @MainActor
    @discardableResult
    static func recordExecutionFailed(planID: UUID, task: AgentTask, modelContext: ModelContext, reason: String? = nil, run: TaskRun? = nil) -> TaskEvent {
        let payload = TaskPlanLifecyclePayload(planID: planID, reason: reason)
        return recordLifecycleEvent(type: TaskPlanEventTypes.executionFailed, payload: payload, task: task, modelContext: modelContext, run: run)
    }

    @MainActor
    @discardableResult
    static func recordStepProgress(
        type: String,
        planID: UUID,
        stepID: String,
        status: TaskPlanPayloadStepStatus,
        task: AgentTask,
        modelContext: ModelContext,
        run: TaskRun? = nil,
        title: String? = nil,
        detail: String? = nil,
        summary: String? = nil,
        reason: String? = nil
    ) -> TaskEvent {
        let payload = TaskPlanProgressPayload(
            version: 1,
            type: type,
            planID: planID,
            stepID: stepID,
            status: status,
            title: title,
            detail: detail,
            summary: summary,
            reason: reason
        )
        let event = TaskEvent(task: task, type: type, payload: encodeStepProgressPayload(payload), run: run)
        modelContext.insert(event)
        task.updatedAt = Date()
        auditStepProgress(payload, task: task, run: run)
        TaskContextStateManager.refresh(task: task)
        return event
    }
}

extension TaskPlanService {
    static func decodePlanPayload(_ payload: String) -> TaskPlanPayload? {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TaskPlanPayload.self, from: data) else {
            return nil
        }
        return normalize(decoded)
    }

    static func decodeStepProgressPayload(_ payload: String) -> TaskPlanProgressPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskPlanProgressPayload.self, from: data)
    }

    static func decodeLifecyclePayload(_ payload: String) -> TaskPlanLifecyclePayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskPlanLifecyclePayload.self, from: data)
    }

    static func inferRisk(from text: String) -> TaskPlanPayloadRisk {
        let lower = text.lowercased()
        if lower.contains("delete") || lower.contains("remove") || lower.contains("write") ||
            lower.contains("edit") || lower.contains("modify") || lower.contains("deploy") ||
            lower.contains("release") || lower.contains("production") {
            return .high
        }
        if lower.contains("test") || lower.contains("build") || lower.contains("network") ||
            lower.contains("install") || lower.contains("run") || lower.contains("api") {
            return .medium
        }
        return .low
    }

    private static func slug(for text: String) -> String {
        let lowercased = text.lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-")
            .prefix(4)
            .joined(separator: "-")
        return String(collapsed.prefix(48))
    }

    static func inferTools(from text: String) -> [String] {
        let lower = text.lowercased()
        var tools = Set<String>()
        if lower.contains("inspect") ||
            lower.contains("read") ||
            lower.contains("review") ||
            lower.contains("open") ||
            lower.contains("check") ||
            lower.contains("verify") ||
            lower.contains("list") {
            tools.insert("Read")
        }
        if lower.contains("search") || lower.contains("find") || lower.contains("grep") {
            tools.insert("Grep")
        }
        if lower.contains("edit") ||
            lower.contains("modify") ||
            lower.contains("update") ||
            lower.contains("fix") ||
            lower.contains("refactor") ||
            lower.contains("polish") ||
            lower.contains("adjust") ||
            lower.contains("replace") ||
            lower.contains("revise") {
            tools.insert("Edit")
        }
        if lower.contains("write") ||
            lower.contains("create") ||
            lower.contains("scaffold") ||
            lower.contains("generate") ||
            lower.contains("add ") ||
            lower.contains("build ") ||
            lower.contains("implement") ||
            lower.contains("populate") ||
            lower.contains("draft") ||
            lower.contains("author") ||
            lower.contains("compose") ||
            lower.contains("save") ||
            lower.contains("touch ") ||
            lower.contains("mkdir") ||
            lower.contains("permission needed") ||
            lower.range(of: #"\.(html|css|js|ts|tsx|jsx|swift|json|md|txt|py|rb|go|rs|java|kt|yml|yaml)\b"#, options: .regularExpression) != nil {
            tools.insert("Write")
        }
        if lower.contains("test") ||
            lower.contains("run test") ||
            lower.contains("run the test") ||
            lower.contains("execute") ||
            lower.contains("install") ||
            lower.contains("compile") ||
            lower.contains("npm ") ||
            lower.contains("swift test") ||
            lower.contains("xcodebuild") ||
            lower.contains("playwright") {
            tools.insert("Bash")
        }
        return sortedLikelyTools(tools.isEmpty ? ["Read"] : Array(tools))
    }

    private static func normalize(_ plan: TaskPlanPayload) -> TaskPlanPayload? {
        guard plan.version == 1 else { return nil }

        let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !goal.isEmpty, !plan.steps.isEmpty else { return nil }

        var seenStepIDs = Set<String>()
        var steps: [TaskPlanPayloadStep] = []
        steps.reserveCapacity(plan.steps.count)

        for step in plan.steps {
            let id = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let stepTitle = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !stepTitle.isEmpty, !seenStepIDs.contains(id) else { return nil }
            seenStepIDs.insert(id)

            let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let doneSignal = step.doneSignal.trimmingCharacters(in: .whitespacesAndNewlines)
            let likelyTools = enrichedLikelyTools(
                existing: step.likelyTools,
                textParts: [stepTitle, detail, doneSignal]
            )

            steps.append(TaskPlanPayloadStep(
                id: id,
                title: stepTitle,
                detail: detail,
                status: step.status,
                risk: step.risk,
                likelyTools: likelyTools,
                doneSignal: doneSignal
            ))
        }

        return TaskPlanPayload(version: 1, planID: plan.planID, title: title, goal: goal, steps: steps)
    }

    private static func enrichedLikelyTools(existing: [String], textParts: [String]) -> [String] {
        var tools = Set(existing.compactMap(normalizedToolName))
        let text = textParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        tools.formUnion(inferTools(from: text))
        return sortedLikelyTools(Array(tools))
    }

    private static func normalizedToolName(_ tool: String) -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return switch trimmed.lowercased() {
        case "read": "Read"
        case "grep", "glob", "search": "Grep"
        case "write": "Write"
        case "edit": "Edit"
        case "bash", "shell", "terminal": "Bash"
        case "webfetch", "web fetch": "WebFetch"
        case "websearch", "web search": "WebSearch"
        default: trimmed
        }
    }

    private static func sortedLikelyTools(_ tools: [String]) -> [String] {
        let priority = ["Read", "Grep", "Write", "Edit", "Bash", "WebFetch", "WebSearch"]
        let order = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($0.element, $0.offset) })
        return Array(Set(tools.compactMap(normalizedToolName))).sorted { lhs, rhs in
            let lhsOrder = order[lhs] ?? Int.max
            let rhsOrder = order[rhs] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func fallbackPlan(from responseText: String, fallbackGoal: String) -> TaskPlanPayload {
        let lines = responseText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = lines.first(where: { !$0.isEmpty })?
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stepTexts = lines.compactMap(extractListItem)
        let fallbackStep = fallbackGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Clarify the requested work."
            : fallbackGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = (stepTexts.isEmpty ? [fallbackStep] : stepTexts).enumerated().map { index, text in
            TaskPlanPayloadStep(
                id: "step-\(index + 1)",
                title: String(text.prefix(96)),
                detail: text,
                risk: inferRisk(from: text),
                likelyTools: inferTools(from: text),
                doneSignal: "The step outcome is reported in chat."
            )
        }

        return TaskPlanPayload(
            title: title?.isEmpty == false ? String(title!.prefix(80)) : "Proposed plan",
            goal: fallbackGoal,
            steps: steps
        )
    }

    @MainActor
    private static func recordPlanEvent(
        type: String,
        plan: TaskPlanPayload,
        task: AgentTask,
        modelContext: ModelContext
    ) -> TaskEvent {
        let event = TaskEvent(task: task, type: type, payload: encodePlanPayload(plan))
        modelContext.insert(event)
        task.updatedAt = Date()
        auditPlanLifecycle(type: type, planID: plan.planID, task: task, stepCount: plan.steps.count)
        TaskContextStateManager.refresh(task: task)
        return event
    }

    @MainActor
    private static func recordLifecycleEvent(
        type: String,
        payload: TaskPlanLifecyclePayload,
        task: AgentTask,
        modelContext: ModelContext,
        run: TaskRun? = nil
    ) -> TaskEvent {
        let event = TaskEvent(task: task, type: type, payload: encode(payload), run: run)
        modelContext.insert(event)
        task.updatedAt = Date()
        let state = reconstruct(for: task)
        auditPlanLifecycle(
            type: type,
            planID: payload.planID,
            task: task,
            reason: payload.reason,
            blockedCount: state.plan?.steps.filter { $0.status == .blocked }.count ?? 0,
            skippedCount: state.plan?.steps.filter { $0.status == .skipped }.count ?? 0,
            run: run
        )
        TaskContextStateManager.refresh(task: task)
        return event
    }

    private static func auditPlanLifecycle(
        type: String,
        planID: UUID,
        task: AgentTask,
        reason: String? = nil,
        stepCount: Int? = nil,
        blockedCount: Int = 0,
        skippedCount: Int = 0,
        run: TaskRun? = nil
    ) {
        let event: AuditEvent
        switch type {
        case TaskPlanEventTypes.created:
            event = .planCreated
        case TaskPlanEventTypes.updated:
            event = .planUpdated
        case TaskPlanEventTypes.approved:
            event = .planApproved
        case TaskPlanEventTypes.cancelled:
            event = .planCancelled
        case TaskPlanEventTypes.executionStarted:
            event = .planExecutionStarted
        case TaskPlanEventTypes.executionCompleted:
            event = .planExecutionCompleted
        case TaskPlanEventTypes.executionFailed:
            event = .planExecutionFailed
        default:
            return
        }

        var fields: [String: String] = [
            "plan_id": planID.uuidString,
            "runtime": task.runtimeID ?? AgentRuntimeID.claudeCode.rawValue,
            "event_count": String(task.events.count),
            "latest_run_status": latestRunStatus(for: task, fallback: run)
        ]
        if let stepCount {
            fields["step_count"] = String(stepCount)
        }
        if blockedCount > 0 {
            fields["blocked_count"] = String(blockedCount)
        }
        if skippedCount > 0 {
            fields["skipped_count"] = String(skippedCount)
        }
        if let reason, !reason.isEmpty {
            fields["reason"] = reason
        }

        let level: LogLevel = event == .planCancelled ? .warning : .info
        AppLogger.audit(event, category: "Plan", taskID: task.id, fields: fields, level: level)
    }

    private static func auditStepProgress(_ payload: TaskPlanProgressPayload, task: AgentTask, run: TaskRun?) {
        var fields: [String: String] = [
            "plan_id": payload.planID?.uuidString ?? "unknown",
            "step_id": payload.stepID,
            "step_status": payload.status.rawValue,
            "runtime": task.runtimeID ?? AgentRuntimeID.claudeCode.rawValue,
            "event_count": String(task.events.count),
            "latest_run_status": latestRunStatus(for: task, fallback: run)
        ]
        if let title = payload.title, !title.isEmpty {
            fields["step_title"] = String(title.prefix(80))
        }
        if let reason = payload.reason, !reason.isEmpty {
            fields["blocked_reason"] = String(reason.prefix(160))
        }
        if let summary = payload.summary, !summary.isEmpty {
            fields["summary"] = String(summary.prefix(160))
        }

        let isBlocked = payload.status == .blocked || payload.type == TaskPlanEventTypes.stepBlocked
        AppLogger.audit(
            isBlocked ? .planStepBlocked : .planStepStateChanged,
            category: "Plan",
            taskID: task.id,
            fields: fields,
            level: isBlocked ? .warning : .debug
        )
    }

    private static func latestRunStatus(for task: AgentTask, fallback: TaskRun? = nil) -> String {
        if let fallback {
            return fallback.status.rawValue
        }
        return task.runs.sorted { $0.startedAt < $1.startedAt }.last?.status.rawValue ?? "none"
    }

    private static func apply(progress: TaskPlanProgressPayload, to state: inout TaskPlanState) {
        guard var plan = state.plan else { return }
        if let progressPlanID = progress.planID, progressPlanID != plan.planID {
            return
        }
        guard let index = plan.steps.firstIndex(where: { $0.id == progress.stepID }) else {
            return
        }

        plan.steps[index].status = progress.status
        if let title = progress.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            plan.steps[index].title = title
        }
        if let detail = progress.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            plan.steps[index].detail = detail
        } else if progress.type == TaskPlanEventTypes.stepBlocked,
                  let reason = progress.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty {
            plan.steps[index].detail = reason
        } else if let summary = progress.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty {
            plan.steps[index].doneSignal = summary
        }
        plan.steps[index].likelyTools = enrichedLikelyTools(
            existing: plan.steps[index].likelyTools,
            textParts: [
                plan.steps[index].title,
                plan.steps[index].detail,
                plan.steps[index].doneSignal,
                progress.reason ?? "",
                progress.summary ?? ""
            ]
        )

        state.plan = plan
    }

    private static func applyRecoveredProtocolProgress(from runs: [TaskRun], to state: inout TaskPlanState) {
        guard state.plan != nil else { return }

        for run in runs.sorted(by: { $0.startedAt < $1.startedAt }) where run.output.contains("ASTRA_EVENT") {
            var filter = AstraRunProtocolTextFilter()
            let outputs = filter.process(text: run.output).outputs + filter.flush().outputs
            for output in outputs {
                guard case .protocolEvent(.valid(.planStep(let progress))) = output else { continue }
                apply(progress: TaskPlanProgressPayload(
                    version: 1,
                    type: progress.type,
                    planID: progress.planID.flatMap(UUID.init(uuidString:)),
                    stepID: progress.stepID,
                    status: TaskPlanPayloadStepStatus(rawValue: progress.status.rawValue) ?? .pending,
                    title: progress.title,
                    detail: progress.detail,
                    summary: progress.summary,
                    reason: progress.reason
                ), to: &state)
            }
        }
    }

    private static func mergeHistoricalStepState(from previous: TaskPlanPayload?, into next: TaskPlanPayload) -> TaskPlanPayload {
        guard let previous, previous.planID == next.planID else { return next }
        let previousStepsByID = Dictionary(uniqueKeysWithValues: previous.steps.map { ($0.id, $0) })
        var merged = next
        for index in merged.steps.indices {
            guard let previousStep = previousStepsByID[merged.steps[index].id] else {
                continue
            }
            merged.steps[index].likelyTools = sortedLikelyTools(merged.steps[index].likelyTools + previousStep.likelyTools)
            guard previousStep.status.isHistoricalTerminalStatus,
                  merged.steps[index].status == .pending else { continue }
            merged.steps[index].status = previousStep.status
        }
        return merged
    }

    private static func matchesCurrentPlan(_ payload: String, state: TaskPlanState) -> Bool {
        guard let currentPlanID = state.plan?.planID else { return true }
        guard let eventPlanID = decodeLifecyclePayload(payload)?.planID else { return true }
        return eventPlanID == currentPlanID
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

    private static func jsonCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if !trimmed.isEmpty {
            candidates.append(trimmed)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = String(line).trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("ASTRA_PLAN ") {
                candidates.append(String(trimmedLine.dropFirst("ASTRA_PLAN ".count)))
            }
        }

        candidates.append(contentsOf: fencedJSONBlocks(in: text))
        candidates.append(contentsOf: balancedJSONObjectCandidates(in: text))

        var seen = Set<String>()
        return candidates.filter { candidate in
            guard candidate.contains("\"steps\""), !seen.contains(candidate) else { return false }
            seen.insert(candidate)
            return true
        }
    }

    private static func stripAstraPlanLines(from text: String) -> String {
        var result = text
        while let prefixRange = result.range(of: "ASTRA_PLAN") {
            guard let objectStart = result[prefixRange.upperBound...].firstIndex(of: "{"),
                  let objectEnd = balancedObjectEnd(in: result, from: objectStart) else {
                let lineStart = result[..<prefixRange.lowerBound].lastIndex(of: "\n").map { result.index(after: $0) } ?? result.startIndex
                let lineEnd = result[prefixRange.upperBound...].firstIndex(of: "\n") ?? result.endIndex
                result.removeSubrange(lineStart..<lineEnd)
                continue
            }

            let lineStart = result[..<prefixRange.lowerBound].lastIndex(of: "\n").map { result.index(after: $0) } ?? prefixRange.lowerBound
            var removalEnd = result.index(after: objectEnd)
            if removalEnd < result.endIndex, result[removalEnd] == "\n" {
                removalEnd = result.index(after: removalEnd)
            }
            result.removeSubrange(lineStart..<removalEnd)
        }
        return result
    }

    private static func stripFencedPlanJSON(from text: String) -> String {
        let pattern = #"```(?:json|JSON)?\s*\n([\s\S]*?)\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()

        var result = text
        for match in matches {
            guard match.numberOfRanges > 1,
                  let bodyRange = Range(match.range(at: 1), in: text),
                  parsePlanPayload(from: String(text[bodyRange])) != nil,
                  let fullRange = Range(match.range, in: result) else {
                continue
            }
            result.removeSubrange(fullRange)
        }
        return result
    }

    private static func stripStandalonePlanJSONLines(from text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("{") && parsePlanPayload(from: trimmed) != nil
        }
        return lines.joined(separator: "\n")
    }

    private static func normalizeVisiblePlanningText(_ text: String) -> String {
        let trimmedLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let regex = try? NSRegularExpression(pattern: #"\n{3,}"#) else {
            return trimmedLines
        }
        let range = NSRange(trimmedLines.startIndex..<trimmedLines.endIndex, in: trimmedLines)
        return regex.stringByReplacingMatches(in: trimmedLines, range: range, withTemplate: "\n\n")
    }

    private static func balancedObjectEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if isEscaped {
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func fencedJSONBlocks(in text: String) -> [String] {
        let pattern = #"```(?:json|JSON)?\s*\n([\s\S]*?)\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let bodyRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[bodyRange])
        }
    }

    private static func balancedJSONObjectCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        let chars = Array(text)
        for start in chars.indices where chars[start] == "{" {
            var depth = 0
            var inString = false
            var isEscaped = false
            for index in start..<chars.count {
                let char = chars[index]
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if char == "\\" {
                    isEscaped = true
                    continue
                }
                if char == "\"" {
                    inString.toggle()
                    continue
                }
                guard !inString else { continue }
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        candidates.append(String(chars[start...index]))
                        break
                    }
                }
            }
        }
        return candidates
    }

    private static func extractListItem(_ line: String) -> String? {
        let patterns = ["- ", "* ", "• "]
        for prefix in patterns where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard let first = line.first, first.isNumber else { return nil }
        let trimmed = line.drop { $0.isNumber }
            .drop { $0 == "." || $0 == ")" || $0 == " " }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
