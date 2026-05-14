import Foundation

enum AgentSensitiveRedactions {
    static func values(for task: AgentTask) -> [String] {
        Array(Set(
            TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables.values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
    }
}
