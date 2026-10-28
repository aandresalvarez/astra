import Foundation
import SwiftData

/// Resolves submission authority from its durable local owner. UUID-only
/// ledgers remain readable only while they name exactly one candidate.
public enum TaskTurnRequestOwnership {
    /// A synchronous operation's derived lookup. Discard before awaiting or
    /// changing candidate/provenance rows; durable models remain authoritative.
    public struct Resolver {
        private let candidates: [UUID: [AgentTask]]
        private var checkedLegacy = Set<UUID>()
        private var legacyOwners: [UUID: AgentTask] = [:]

        public init(candidates: [AgentTask]) {
            self.candidates = Dictionary(grouping: candidates.filter { !$0.isDeleted }, by: \.id)
        }

        public mutating func resolve(_ request: TaskTurnRequest) -> AgentTask? {
            resolve(taskID: request.taskID, policy: request.executionPolicySnapshotJSON)
        }

        public mutating func resolve(_ request: TaskTurnRequestSnapshot) -> AgentTask? {
            resolve(taskID: request.taskID, policy: request.executionPolicySnapshotJSON)
        }

        private mutating func resolve(taskID: UUID, policy: String?) -> AgentTask? {
            let tasks = candidates[taskID] ?? []
            switch TaskTurnOwnerBinding(json: policy) {
            case .owner(let owner): return tasks.first { $0.persistentModelID == owner }
            case .legacy:
                if checkedLegacy.insert(taskID).inserted, tasks.count == 1, let task = tasks.first,
                   TaskHistoryRead.events(for: task, ofTypes: [TaskEventTypes.Task.historyImported.rawValue]).isEmpty {
                    legacyOwners[taskID] = task
                }
                return legacyOwners[taskID]
            case .invalid: return nil
            }
        }
    }

    public static func resolve(_ request: TaskTurnRequest, among candidates: [AgentTask]) -> AgentTask? {
        var resolver = Resolver(candidates: candidates)
        return resolver.resolve(request)
    }

    public static func resolve(_ request: TaskTurnRequestSnapshot, among candidates: [AgentTask]) -> AgentTask? {
        var resolver = Resolver(candidates: candidates)
        return resolver.resolve(request)
    }

    public static func candidates(taskID: UUID, in context: ModelContext) throws -> [AgentTask] {
        try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
    }

    public static func resolve(_ request: TaskTurnRequest, in context: ModelContext) throws -> AgentTask? {
        resolve(request, among: try candidates(taskID: request.taskID, in: context))
    }

    public static func owned(_ requests: [TaskTurnRequest], by task: AgentTask, in context: ModelContext) throws -> [TaskTurnRequest] {
        var resolver = Resolver(candidates: try candidates(taskID: task.id, in: context))
        let owner = task.persistentModelID
        return requests.filter { resolver.resolve($0)?.persistentModelID == owner }
    }

    /// Import/delete must not turn an ambiguous old request into an executable
    /// request merely by changing the number of rows sharing its portable ID.
    /// This mutation is saved with the importing/deleting service transaction.
    public static func preserveLegacyBindings(taskID: UUID, in context: ModelContext) throws {
        let tasks = try candidates(taskID: taskID, in: context).filter { !$0.isDeleted }
        let requests = try context.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate { $0.taskID == taskID }))
        var resolver = Resolver(candidates: tasks)
        for request in requests where TaskTurnOwnerBinding(json: request.executionPolicySnapshotJSON) == .legacy {
            if let task = resolver.resolve(request), task.persistentModelID.storeIdentifier != nil {
                request.executionPolicySnapshotJSON = TaskTurnOwnerBinding.rebinding(
                    request.executionPolicySnapshotJSON ?? "{}", to: task)
            } else {
                // Preserve any existing launch policy, but permanently deny an
                // owner that cannot be identified. Never pick the first copy.
                var policy = request.executionPolicySnapshotJSON.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                policy["taskOwnerID"] = NSNull()
                request.executionPolicySnapshotJSON = String(data: try JSONSerialization.data(withJSONObject: policy), encoding: .utf8)
                request.blockerSummary = "The saved request does not identify which imported copy owns it. Start a new request in the intended copy."
            }
        }
    }
}
