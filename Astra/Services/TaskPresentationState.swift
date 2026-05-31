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

enum TaskPresentationState {
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
                title: "Completed without automated verification",
                summary: "Manual completion",
                detail: detail,
                systemImage: "checkmark.circle",
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
        let summary = verification.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            parts.append(summary)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
