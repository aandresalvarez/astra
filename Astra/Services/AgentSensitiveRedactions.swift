import Foundation

enum AgentSensitiveRedactions {
    static func values(for task: AgentTask) -> [String] {
        Array(Set(
            task.resolvedEnvironmentVariables.values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
    }
}
