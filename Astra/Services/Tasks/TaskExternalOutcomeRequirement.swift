import Foundation
import ASTRAModels

enum TaskExternalOutcomeEventTypes {
    static let publicationRequested = "git.publish.requested"
    static let publicationProposed = "git.publish.proposed"
    static let publicationApproved = "git.publish.approved"
    static let publicationReceipt = "git.publish.receipt"
    static let publicationFailed = "git.publish.failed"
}

enum TaskRequiredExternalOutcomeKind: String, Codable, Sendable, Equatable {
    case githubPullRequest = "github_pull_request"
}

struct TaskRequiredExternalOutcomeRequest: Codable, Sendable, Equatable {
    let version: Int
    let kind: TaskRequiredExternalOutcomeKind
    let runID: UUID
    let sourceEventID: UUID?
    let message: String

    init(
        kind: TaskRequiredExternalOutcomeKind,
        runID: UUID,
        sourceEventID: UUID? = nil,
        message: String
    ) {
        version = 1
        self.kind = kind
        self.runID = runID
        self.sourceEventID = sourceEventID
        self.message = message
    }
}

/// Resolves ASTRA-owned publication intent from durable task events. Ask mode
/// records a request when local work completes; legacy failed provider
/// publication attempts remain readable so existing tasks keep working.
enum TaskExternalOutcomeRequirementResolver {
    @MainActor
    static func pendingGitHubPullRequest(
        task: AgentTask,
        run: TaskRun? = nil
    ) -> TaskRequiredExternalOutcomeRequest? {
        let targetRun = run ?? task.runs.sorted(by: TaskRun.isChronologicallyOrdered).last
        guard let targetRun else { return nil }

        let requestEvent = task.events
            .filter {
                $0.run?.id == targetRun.id
                    && $0.type == TaskExternalOutcomeEventTypes.publicationRequested
            }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .last
        if let requestEvent,
           let data = requestEvent.payload.data(using: .utf8),
           let request = try? TaskEventPayloadCodec.makeDecoder().decode(
            TaskRequiredExternalOutcomeRequest.self,
            from: data
           ) {
            let hasMatchingReceipt = task.events.contains {
                $0.run?.id == targetRun.id
                    && $0.type == TaskExternalOutcomeEventTypes.publicationReceipt
                    && $0.timestamp >= requestEvent.timestamp
            }
            guard !hasMatchingReceipt else { return nil }
            return TaskRequiredExternalOutcomeRequest(
                kind: request.kind,
                runID: request.runID,
                sourceEventID: requestEvent.id,
                message: request.message
            )
        }

        // Mutable task wording is only a compatibility signal for historical
        // provider failures. Once ASTRA records a typed request, the event is
        // the authority even if the user later edits the title or goal.
        guard requestsGitHubPullRequest(task) else { return nil }
        guard let failure = TaskExternalOutcomeFailureClassifier.pendingGitHubPullRequestFailure(
            task: task,
            run: targetRun
        ) else { return nil }
        return TaskRequiredExternalOutcomeRequest(
            kind: failure.kind,
            runID: failure.runID,
            sourceEventID: failure.sourceEventID,
            message: failure.message
        )
    }

    @MainActor
    static func makeGitHubPullRequest(
        task: AgentTask,
        run: TaskRun,
        message: String = "ASTRA Ask mode is waiting for review of the exact draft pull request proposal."
    ) -> TaskRequiredExternalOutcomeRequest? {
        guard requestsGitHubPullRequest(task) else { return nil }
        return TaskRequiredExternalOutcomeRequest(
            kind: .githubPullRequest,
            runID: run.id,
            message: message
        )
    }

    @MainActor
    static func hasPendingGitHubPullRequest(task: AgentTask) -> Bool {
        pendingGitHubPullRequest(task: task) != nil
    }

    static func requestsGitHubPullRequest(_ task: AgentTask) -> Bool {
        GitOperationIntentDetector.detectsPullRequestPublicationIntent(
            prompt: task.acceptanceCriteria.joined(separator: "\n"),
            task: task,
            contextText: task.constraints.joined(separator: "\n")
        )
    }
}
