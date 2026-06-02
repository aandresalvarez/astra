import Foundation

enum TaskVerificationTone: String, Equatable {
    case verified
    case attention
    case failed
    case neutral
}

struct TaskVerificationPresentation: Equatable {
    let title: String
    let summary: String
    let detail: String?
    let systemImage: String
    let tone: TaskVerificationTone
}

enum TaskReviewTone: String, Equatable {
    case quiet
    case attention
    case failed
    case closed
}

struct TaskReviewPresentation: Equatable {
    let runOutcomeLabel: String
    let reviewLabel: String?
    let composerLabel: String?
    let composerIcon: String?
    let composerHelp: String?
    let tone: TaskReviewTone
    let decisionTitle: String
    let decisionDetail: String
}

enum TaskPresentationState {
    static let closedColumnTitle = "Closed"
    static let closeTaskActionTitle = "Close task"
    static let closeAnywayActionTitle = "Close anyway"
    static let closeWithoutRunningPlanActionTitle = "Close without running plan"
    static let reopenTaskActionTitle = "Reopen task"

    static func statusColor(for status: TaskStatus) -> String {
        switch status {
        case .draft: return "purple"
        case .queued: return "gray"
        case .running: return "blue"
        case .pendingUser: return "orange"
        case .completed: return "green"
        case .failed: return "red"
        case .cancelled: return "gray"
        case .budgetExceeded: return "red"
        }
    }

    static func reviewPresentation(status: TaskStatus, isClosed: Bool) -> TaskReviewPresentation {
        let outcome = runOutcomeLabel(for: status)

        if isClosed {
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: closedColumnTitle,
                composerLabel: closedColumnTitle,
                composerIcon: "checkmark.circle.fill",
                composerHelp: "You closed this task. Reopen it to continue working.",
                tone: .closed,
                decisionTitle: "Task closed",
                decisionDetail: "Reopen it here if you need to continue with this task."
            )
        }

        switch status {
        case .draft:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: nil,
                composerLabel: nil,
                composerIcon: nil,
                composerHelp: nil,
                tone: .quiet,
                decisionTitle: "Draft",
                decisionDetail: "Queue or run this task when it is ready."
            )
        case .queued:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: nil,
                composerLabel: nil,
                composerIcon: nil,
                composerHelp: nil,
                tone: .quiet,
                decisionTitle: "Ready to run",
                decisionDetail: "Start this task now, or refine it first."
            )
        case .running:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: nil,
                composerLabel: nil,
                composerIcon: nil,
                composerHelp: nil,
                tone: .quiet,
                decisionTitle: "Run in progress",
                decisionDetail: "The agent is currently working on this task."
            )
        case .pendingUser:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: "Needs input",
                composerLabel: "Needs input",
                composerIcon: "person.crop.circle.badge.questionmark",
                composerHelp: "The task is waiting for your review or approval.",
                tone: .attention,
                decisionTitle: "Input needed",
                decisionDetail: "Use the review controls above the composer to continue."
            )
        case .completed:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: "Needs review",
                composerLabel: "Needs review",
                composerIcon: "eye.fill",
                composerHelp: "The run finished. Review the result, then close the task when no action remains.",
                tone: .attention,
                decisionTitle: "Ready to close?",
                decisionDetail: "Close this task when the current result no longer needs action."
            )
        case .failed:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: "Needs review",
                composerLabel: "Needs review",
                composerIcon: "exclamationmark.triangle.fill",
                composerHelp: "The run failed. Review the result, then retry, resume, or close the task.",
                tone: .failed,
                decisionTitle: "Run stopped",
                decisionDetail: "Review the failure, then retry, resume, or close the task."
            )
        case .budgetExceeded:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: "Needs review",
                composerLabel: "Needs review",
                composerIcon: "speedometer",
                composerHelp: "The run hit the token budget. Raise the budget, resume, retry, or close the task.",
                tone: .failed,
                decisionTitle: "Budget hit",
                decisionDetail: "Raise the budget and resume, retry this task from scratch, or close it."
            )
        case .cancelled:
            return TaskReviewPresentation(
                runOutcomeLabel: outcome,
                reviewLabel: "Needs review",
                composerLabel: "Needs review",
                composerIcon: "xmark.circle.fill",
                composerHelp: "The run was cancelled. Review the partial result, then retry or close the task.",
                tone: .attention,
                decisionTitle: "Run cancelled",
                decisionDetail: "Review the partial result, then retry or close the task."
            )
        }
    }

    static func verificationPresentation(for verification: TaskContextState.Verification) -> TaskVerificationPresentation {
        let status = verification.status.lowercased()
        let detail = verificationDetail(for: verification)

        if verification.completionVerified || status == "passed" {
            return TaskVerificationPresentation(
                title: "Verification passed",
                summary: "Verified",
                detail: detail,
                systemImage: "checkmark.seal.fill",
                tone: .verified
            )
        }

        if status == "manual_completion" {
            return TaskVerificationPresentation(
                title: "No automated verification",
                summary: "No automated verification",
                detail: detail,
                systemImage: "checkmark.circle",
                tone: .attention
            )
        }

        if status == "review_needed" {
            return TaskVerificationPresentation(
                title: "Needs review",
                summary: "Needs review",
                detail: detail,
                systemImage: "eye.fill",
                tone: .attention
            )
        }

        if ["failed", "budget_exceeded", "timeout", "error"].contains(status) {
            return TaskVerificationPresentation(
                title: "Verification failed",
                summary: "Verification failed",
                detail: detail,
                systemImage: "exclamationmark.triangle.fill",
                tone: .failed
            )
        }

        return TaskVerificationPresentation(
            title: "Not verified yet",
            summary: "Not verified",
            detail: detail,
            systemImage: "questionmark.circle",
            tone: .neutral
        )
    }

    private static func verificationDetail(for verification: TaskContextState.Verification) -> String? {
        var parts: [String] = []
        parts.append("\(verification.status) via \(verification.strategy)")
        if let command = verification.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            parts.append("Command: \(command)")
        }
        let artifactStatus = verification.artifactStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artifactStatus.isEmpty, artifactStatus != "unknown" {
            parts.append("Artifacts: \(artifactStatus)")
        }
        if let deliverableLevel = verification.deliverableLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deliverableLevel.isEmpty {
            parts.append("Deliverable quality: \(deliverableLevel)")
        }
        let failedChecks = verification.deliverableChecks
            .filter { $0.status == TaskDeliverableCheckStatus.failed.rawValue }
            .prefix(2)
            .map { "\($0.title): \($0.summary)" }
        for check in failedChecks {
            parts.append(check)
        }
        let summary = verification.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            parts.append(summary)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private static func runOutcomeLabel(for status: TaskStatus) -> String {
        switch status {
        case .draft: return "Draft"
        case .queued: return "Queued"
        case .running: return "Run in progress"
        case .pendingUser: return "Waiting for input"
        case .completed: return "Run finished"
        case .failed: return "Run failed"
        case .cancelled: return "Run cancelled"
        case .budgetExceeded: return "Budget hit"
        }
    }
}
