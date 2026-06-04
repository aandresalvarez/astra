import Foundation

enum AgentSensitiveRedactions {
    static func values(for task: AgentTask) -> [String] {
        let capabilityScope = TaskCapabilityResolver(task: task)
            .resolvedScope(.fullInventory)
        return Array(Set(
            capabilityScope.resolver.resolvedEnvironmentVariables.values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
    }
}
