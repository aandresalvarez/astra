import Foundation

@MainActor
enum AgentPromptExecutionEnvironmentSection {
    static func section(for task: AgentTask, codeDir: String) -> PromptContextSection? {
        let environment = DockerExecutionPlanner.resolveEnvironment(for: task)
        guard environment.isContainerized else { return nil }

        let mapper = ExecutionEnvironmentPathMapper(mounts: environment.mounts)
        let containerCodeDir = mapper.containerPath(forHostPath: codeDir) ?? environment.containerWorkingDirectory
        let taskDir = TaskWorkspaceAccess(task: task).taskFolder
        let containerTaskDir = mapper.containerPath(forHostPath: taskDir) ?? "/astra/task"
        return PromptContextSection(
            kind: .supportingContext,
            text: """
            Execution Environment: \(environment.displayName) (\(environment.kind.rawValue))
            Container working directory: \(containerCodeDir)
            Container task output folder: \(containerTaskDir)
            Host workspace files are bind-mounted into the container; use the container paths above while running commands.
            """,
            sourcePointers: [codeDir, taskDir].map {
                PromptContextSourcePointer(label: "workspace path", target: $0)
            }
        )
    }
}

