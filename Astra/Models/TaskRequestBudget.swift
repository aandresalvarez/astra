import Foundation
import ASTRACore

/// Derived presentation only. Launch authorization and limits remain owned by
/// the execution journal; its admission/result events provide reloadable views.
public struct TaskRequestBudget: Equatable, Sendable {
    public static let exhaustedMessage = "This request reached its budget. Retry keeps the remaining allowance. Send a new message to start a new request with its own budget."
    public let tokensUsed: Int
    public let tokenCeiling: Int
    public let reconciliationPending: Bool
    public var progress: Double {
        guard !reconciliationPending, tokenCeiling > 0, tokenCeiling != Int.max else { return 0 }
        return min(1, max(0, Double(tokensUsed) / Double(tokenCeiling)))
    }
    public init(tokensUsed: Int, tokenCeiling: Int, reconciliationPending: Bool = false) {
        self.reconciliationPending = reconciliationPending
        self.tokensUsed = max(0, tokensUsed); self.tokenCeiling = tokenCeiling
    }
    public init(run: TaskRun, task: AgentTask) { self = Index(events: task.events).budget(for: run, task: task) }

    /// Built once per history page/snapshot, never once per run.
    public struct Index {
        private struct Checkpoint: Decodable { let requestTokensUsed: Int?; let effectiveTokenBudget: Int }
        private struct Admission: Decodable {
            struct Limits: Decodable { let tokensSpent: Int; let tokenCeiling: Int }
            let runID: UUID?; let limits: Limits
        }
        private var admissions: [UUID: (date: Date, usage: TaskRequestBudget)] = [:]
        private var results: [UUID: TaskRequestBudget] = [:]
        private var estimatedSessions: [String: Date] = [:]
        public init(events: [TaskEvent]) {
            for event in events {
                guard let run = event.run else { continue }
                let id = run.id
                if event.type == "task.stats", event.payload.hasPrefix("estimated tokens:"),
                   let key = Self.cumulativeSessionKey(run) {
                    estimatedSessions[key] = min(estimatedSessions[key] ?? .distantFuture, run.startedAt)
                }
                if event.type == TaskEventTypes.System.runtimeResultCaptured.rawValue,
                   let value = try? JSONDecoder().decode(Checkpoint.self, from: Data(event.payload.utf8)),
                   let spent = value.requestTokensUsed {
                    results[id] = .init(tokensUsed: spent, tokenCeiling: value.effectiveTokenBudget)
                } else if event.type == TaskEventTypes.System.runtimeExecutionOwnership.rawValue,
                          admissions[id] == nil || event.timestamp < admissions[id]!.date,
                          let value = try? JSONDecoder().decode(Admission.self, from: Data(event.payload.utf8)), value.runID == id {
                    admissions[id] = (event.timestamp, .init(tokensUsed: value.limits.tokensSpent, tokenCeiling: value.limits.tokenCeiling))
                }
            }
        }
        private static func cumulativeSessionKey(_ run: TaskRun) -> String? {
            guard let runtime = run.runtimeID, ["codex_cli", "copilot_cli", "antigravity_cli"].contains(runtime),
                  let session = run.providerSessionId, !session.isEmpty else { return nil }
            return runtime + ":" + session
        }
        public func budget(for run: TaskRun, task: AgentTask) -> TaskRequestBudget {
            if let result = results[run.id] { return result }
            let previous = admissions[run.id]?.usage
            return .init(tokensUsed: ProviderUsageArithmetic.adding(previous?.tokensUsed ?? 0, run.tokensUsed),
                         tokenCeiling: min(previous?.tokenCeiling ?? Int.max, task.tokenBudget > 0 ? task.tokenBudget : Int.max),
                         reconciliationPending: Self.cumulativeSessionKey(run).flatMap { estimatedSessions[$0] }.map { $0 < run.startedAt } ?? false)
        }
    }
}
