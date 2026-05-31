import Foundation
import SwiftData

enum MissionControlTone: String, Equatable {
    case verified
    case attention
    case failed
    case running
    case neutral
}

struct MissionControlAssertionRow: Equatable, Identifiable {
    var id: String
    var status: String
    var method: String
    var required: Bool
    var description: String
}

struct MissionControlCorrection: Equatable {
    var correctiveStepID: String
    var failedAssertionID: String
    var status: String
    var suggestedRepair: String
}

struct MissionControlPresentation: Equatable {
    var objective: String
    var statusTitle: String
    var statusSummary: String
    var tone: MissionControlTone
    var activeStepTitle: String?
    var validationSummary: String
    var assertionRows: [MissionControlAssertionRow]
    var latestHandoffSummary: String?
    var blockerCount: Int
    var artifactCount: Int
    var changedFileCount: Int
    var budgetSummary: String
    var nextAction: String?
    var correction: MissionControlCorrection?
    var sourcePointerCount: Int

    var isSourceBacked: Bool { sourcePointerCount > 0 }

    @MainActor
    static func build(
        task: AgentTask,
        planState: TaskPlanState,
        state: TaskContextState?
    ) -> MissionControlPresentation? {
        guard state != nil || planState.plan != nil || !task.events.isEmpty || !task.runs.isEmpty else {
            return nil
        }

        let objective = firstNonEmpty(
            state?.objective.currentObjective,
            planState.plan?.goal,
            task.goal
        )
        let assertionRows = state?.validationContract?.assertions.map {
            MissionControlAssertionRow(
                id: $0.id,
                status: $0.status,
                method: $0.method,
                required: $0.required,
                description: $0.description
            )
        } ?? []
        let validationSummary = validationSummary(for: state?.validationContract)
        let correction = state?.correctiveWork?
            .first(where: { ["proposed", "approved", "task_created"].contains($0.status) })
            .map {
                MissionControlCorrection(
                    correctiveStepID: $0.correctiveStepID,
                    failedAssertionID: $0.failedAssertionID,
                    status: $0.status,
                    suggestedRepair: $0.suggestedRepair
                )
            }
        let status = statusPresentation(task: task, state: state, correction: correction)
        let latestHandoffSummary = state?.latestHandoff.map { handoff in
            let next = handoff.suggestedNextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let next, !next.isEmpty {
                return next
            }
            if let unfinished = handoff.unfinishedWork.first {
                return unfinished
            }
            return handoff.completedWork.first ?? "Handoff recorded"
        }
        let activeStep = planState.plan.flatMap { TaskPlanService.nextExecutableStep(in: $0) }

        return MissionControlPresentation(
            objective: objective,
            statusTitle: status.title,
            statusSummary: status.summary,
            tone: status.tone,
            activeStepTitle: activeStep?.title,
            validationSummary: validationSummary,
            assertionRows: assertionRows,
            latestHandoffSummary: latestHandoffSummary,
            blockerCount: state?.blockerFacts.count ?? state?.blockers.count ?? 0,
            artifactCount: state?.artifacts.count ?? task.artifacts.count,
            changedFileCount: state?.changedFiles.count ?? task.runs.flatMap(\.fileChanges).count,
            budgetSummary: budgetSummary(task: task),
            nextAction: state?.nextLikelyAction,
            correction: correction,
            sourcePointerCount: state?.sourcePointers.count ?? 0
        )
    }

    @MainActor
    static func recordAction(
        _ actionType: String,
        task: AgentTask,
        correctiveStepID: String? = nil,
        correctiveTaskID: UUID? = nil,
        reason: String? = nil,
        modelContext: ModelContext
    ) {
        let payload = TaskMissionActionPayload(
            version: 1,
            action: actionType,
            correctiveStepID: correctiveStepID,
            correctiveTaskID: correctiveTaskID,
            reason: reason,
            createdAt: isoTimestamp(Date())
        )
        modelContext.insert(TaskEvent(task: task, type: actionType, payload: encode(payload)))
        AppLogger.audit(auditEvent(for: actionType), category: "Mission", taskID: task.id, fields: [
            "action": actionType,
            "corrective_step_id": correctiveStepID ?? "none",
            "corrective_task_id": correctiveTaskID?.uuidString ?? "none",
            "reason": reason ?? "none"
        ])
        TaskContextStateManager.refresh(task: task)
    }

    private static func statusPresentation(
        task: AgentTask,
        state: TaskContextState?,
        correction: MissionControlCorrection?
    ) -> (title: String, summary: String, tone: MissionControlTone) {
        if let correction {
            return (
                "Needs correction",
                "Failed assertion \(correction.failedAssertionID)",
                .failed
            )
        }
        if let contract = state?.validationContract {
            switch contract.status {
            case "passed":
                return ("Verified", "\(contract.requiredPassed)/\(contract.requiredTotal) required proofs passed", .verified)
            case "failed":
                return ("Validation failed", "\(contract.requiredPassed)/\(contract.requiredTotal) required proofs passed", .failed)
            case "running":
                return ("Validating", "\(contract.requiredPassed)/\(contract.requiredTotal) required proofs passed", .running)
            default:
                return ("Not verified", "\(contract.requiredPassed)/\(contract.requiredTotal) required proofs passed", .attention)
            }
        }
        switch task.status {
        case .running:
            return ("Running", "Worker is active", .running)
        case .completed:
            return ("Completed", "No validation contract recorded", .attention)
        case .pendingUser, .failed, .budgetExceeded:
            return ("Needs attention", task.status.rawValue, .failed)
        default:
            return ("Mission ready", task.status.rawValue, .neutral)
        }
    }

    private static func validationSummary(for contract: TaskContextState.ValidationContractSummary?) -> String {
        guard let contract else { return "No validation contract" }
        return "\(contract.status): \(contract.requiredPassed)/\(contract.requiredTotal) required, \(contract.assertionCount) assertions"
    }

    private static func budgetSummary(task: AgentTask) -> String {
        let budget = task.tokenBudget > 0 ? Formatters.formatTokens(task.tokenBudget) : "unlimited"
        let used = Formatters.formatTokens(task.tokensUsed)
        if task.costUSD > 0 {
            return "\(used) used / \(budget), \(String(format: "$%.2f", task.costUSD))"
        }
        return "\(used) used / \(budget)"
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Untitled mission"
    }

    private static func auditEvent(for actionType: String) -> AuditEvent {
        switch actionType {
        case TaskMissionActionEventTypes.approved:
            return .missionActionApproved
        case TaskMissionActionEventTypes.dismissed:
            return .missionActionDismissed
        case TaskMissionActionEventTypes.retryRequested:
            return .missionActionRetryRequested
        case TaskMissionActionEventTypes.correctionCreated:
            return .missionActionCorrectionCreated
        default:
            return .userAction
        }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func encode<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
