import Foundation
import ASTRACore
import ASTRAModels

enum AgentSensitiveRedactions {
    /// Values worth scrubbing from a task's session history.
    ///
    /// Two sources, deliberately: the task's full capability inventory, which
    /// is broader than "things named like a secret" and catches values the run
    /// never actually received, and the run's registered credential set, which
    /// catches values the inventory can no longer resolve — a connector
    /// deleted, or reachable only through the broker.
    static func values(for task: AgentTask) -> [String] {
        let capabilityScope = TaskCapabilityResolver(task: task)
            .resolvedScope(.fullInventory)
        var values = Set(
            capabilityScope.resolver.resolvedEnvironmentVariables.values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        values.formUnion(RunSecretRedactionScope.secrets(for: task.id))
        return Array(values)
    }
}
