import Foundation
import ASTRACore
import ASTRAModels

/// Prepares the two execution-environment views owned by a provider run.
/// Task state retains only durable/static mounts, while the run view also
/// includes current-message inputs whose lifetime is limited to that run.
struct AgentRuntimeRunEnvironmentContext: Sendable, Equatable {
    let taskSnapshot: WorkspaceExecutionEnvironment
    let runSnapshot: WorkspaceExecutionEnvironment

    @MainActor
    static func prepare(
        task: AgentTask,
        currentDirectory: String,
        providerLaunchContextText: String
    ) -> AgentRuntimeRunEnvironmentContext {
        let taskSnapshot = DockerExecutionPlanner.snapshotForRun(
            task: task,
            currentDirectory: currentDirectory
        )
        let runSnapshot = DockerExecutionPlanner.snapshotForRun(
            task: task,
            currentDirectory: currentDirectory,
            additionalReadOnlyInputPaths: AgentRuntimeAttachmentProjection.readablePaths(
                for: task,
                contextText: providerLaunchContextText
            )
        )
        return AgentRuntimeRunEnvironmentContext(
            taskSnapshot: taskSnapshot,
            runSnapshot: runSnapshot
        )
    }

    func appendingReadOnlyInputGuidance(to prompt: String) -> String {
        guard let guidance = Self.readOnlyInputGuidance(for: runSnapshot) else { return prompt }
        return prompt + "\n\n" + guidance
    }

    private static func readOnlyInputGuidance(
        for environment: WorkspaceExecutionEnvironment
    ) -> String? {
        guard environment.isContainerized else { return nil }
        let mappings = environment.mounts
            .filter { $0.role == .additionalPath && $0.access == .readOnly }
            .sorted {
                ($0.containerPath, $0.hostPath) < ($1.containerPath, $1.hostPath)
            }
        guard !mappings.isEmpty else { return nil }
        let lines = mappings.map { "- \($0.hostPath) -> \($0.containerPath) (read-only)" }
        return """
        Docker read-only input path mapping:
        \(lines.joined(separator: "\n"))
        When the provider or a workspace tool runs inside Docker, read these inputs through the container paths above; host paths are not available inside the container. Do not edit these inputs.
        """
    }
}
