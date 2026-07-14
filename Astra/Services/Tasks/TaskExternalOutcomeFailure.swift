import Foundation
import ASTRAModels

struct ToolResultFailurePayload: Codable, Sendable, Equatable {
    let version: Int
    let toolID: String
    let message: String
    let toolUseEvidence: String?

    init(toolID: String, message: String, toolUseEvidence: String? = nil) {
        version = 2
        self.toolID = toolID
        self.message = message
        self.toolUseEvidence = toolUseEvidence
    }

    static func decode(from payload: String) -> Self? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? TaskEventPayloadCodec.makeDecoder().decode(Self.self, from: data)
    }

    static func decodeMessage(from payload: String) -> String {
        decode(from: payload)?.message ?? payload
    }
}

struct TaskRequiredExternalOutcomeFailure: Codable, Sendable, Equatable {
    let version: Int
    let kind: TaskRequiredExternalOutcomeKind
    let runID: UUID
    let sourceEventID: UUID?
    let message: String
}

/// Interprets structured failed tool results in the context of the task's
/// explicit deliverable. A failed incidental command is not a completion gate;
/// a failed GitHub publication is a gate only when the user actually requested
/// a pull request and there is no later durable publication receipt.
enum TaskExternalOutcomeFailureClassifier {
    @MainActor
    static func pendingGitHubPullRequestFailure(
        task: AgentTask,
        run: TaskRun? = nil
    ) -> TaskRequiredExternalOutcomeFailure? {
        guard TaskExternalOutcomeRequirementResolver.requestsGitHubPullRequest(task) else { return nil }
        let targetRun = run ?? task.runs.sorted(by: TaskRun.isChronologicallyOrdered).last
        guard let targetRun else { return nil }

        let runEvents = task.events
            .filter { $0.run?.id == targetRun.id }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let receiptTimestamp = task.events
            .filter { $0.type == TaskExternalOutcomeEventTypes.publicationReceipt }
            .map(\.timestamp)
            .max()
        let durableFailure = runEvents
            .filter { $0.type == TaskExternalOutcomeEventTypes.publicationFailed }
            .reversed()
            .compactMap({ event -> (TaskRequiredExternalOutcomeFailure, Date)? in
                guard let data = event.payload.data(using: .utf8),
                      let failure = try? TaskEventPayloadCodec.makeDecoder().decode(
                        TaskRequiredExternalOutcomeFailure.self,
                        from: data
                      ) else { return nil }
                return (failure, event.timestamp)
            })
            .first
        if let durableFailure,
           receiptTimestamp.map({ $0 < durableFailure.1 }) ?? true {
            return durableFailure.0
        }

        let failedEvents = runEvents
            .filter { $0.type == TaskEventTypes.Tool.resultFailed.rawValue }
            .reversed()
        for failedEvent in failedEvents {
            let hasLaterReceipt = task.events.contains {
                $0.type == TaskExternalOutcomeEventTypes.publicationReceipt
                    && $0.timestamp >= failedEvent.timestamp
            }
            guard !hasLaterReceipt else { continue }

            let decoded = ToolResultFailurePayload.decode(from: failedEvent.payload)
            let legacyPrecedingToolUse = runEvents.last {
                $0.type == TaskEventTypes.Tool.use.rawValue && $0.timestamp <= failedEvent.timestamp
            }?.payload ?? ""
            let message = decoded?.message ?? failedEvent.payload
            let evidence = "\(decoded?.toolUseEvidence ?? legacyPrecedingToolUse)\n\(message)".lowercased()
            guard describesPullRequestPublication(evidence) else { continue }

            return TaskRequiredExternalOutcomeFailure(
                version: 1,
                kind: .githubPullRequest,
                runID: targetRun.id,
                sourceEventID: failedEvent.id,
                message: String(message.prefix(1_000))
            )
        }
        return nil
    }

    @MainActor
    static func failureForGitHubPullRequestEvidence(
        task: AgentTask,
        run: TaskRun,
        evidence: String,
        sourceEventID: UUID? = nil
    ) -> TaskRequiredExternalOutcomeFailure? {
        guard TaskExternalOutcomeRequirementResolver.requestsGitHubPullRequest(task),
              describesPullRequestPublication(evidence.lowercased()) else {
            return nil
        }
        return TaskRequiredExternalOutcomeFailure(
            version: 1,
            kind: .githubPullRequest,
            runID: run.id,
            sourceEventID: sourceEventID,
            message: String(evidence.prefix(1_000))
        )
    }

    @MainActor
    static func hasPendingGitHubPullRequestFailure(task: AgentTask) -> Bool {
        pendingGitHubPullRequestFailure(task: task) != nil
    }

    private static func describesPullRequestPublication(_ evidence: String) -> Bool {
        [
            "gh pr create",
            "pr create",
            "pull request",
            "createpullrequest",
            "create_pull_request"
        ].contains { evidence.contains($0) }
    }
}
