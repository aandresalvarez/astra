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
        let credentialLine = credentialProjectionLine(for: environment)
        if environment.workspaceCommandsRunInsideContainer {
            return PromptContextSection(
                kind: .supportingContext,
                text: """
                Execution Environment: \(environment.displayName) (\(environment.kind.rawValue))
                Provider placement: host macOS
                Workspace command executor: Docker image \(environment.image ?? environment.displayName)
                Container working directory: \(containerCodeDir)
                Container task output folder: \(containerTaskDir)
                \(credentialLine)
                Run project commands with the ASTRA workspace MCP tool; it executes inside the Docker container. Claude-style runtimes call it as `mcp__astra_workspace__workspace_shell`, and GitHub Copilot CLI displays it as `astra_workspace-workspace_shell`. Do not use native host Bash for project commands in this workspace. Host workspace files are bind-mounted into the container; use the container paths above while running commands and report host paths in final summaries when relevant.
                Prefer tools installed in the image environment. Check tools by name from the container PATH, such as `command -v dbt && dbt --version`, through the ASTRA workspace MCP tool.
                Do not use host-created virtual environments from bind-mounted workspace paths, such as `/workspace/.venv`; macOS virtualenv symlinks and compiled extensions are not portable to Linux containers.
                """,
                sourcePointers: [codeDir, taskDir].map {
                    PromptContextSourcePointer(label: "workspace path", target: $0)
                }
            )
        }
        return PromptContextSection(
            kind: .supportingContext,
            text: """
            Execution Environment: \(environment.displayName) (\(environment.kind.rawValue))
            Provider placement: container
            Container working directory: \(containerCodeDir)
            Container task output folder: \(containerTaskDir)
            \(credentialLine)
            Host workspace files are bind-mounted into the container; use the container paths above while running commands.
            """,
            sourcePointers: [codeDir, taskDir].map {
                PromptContextSourcePointer(label: "workspace path", target: $0)
            }
        )
    }

    private static func credentialProjectionLine(for environment: WorkspaceExecutionEnvironment) -> String {
        let projections = environment.effectiveCredentialProjections
        guard !projections.isEmpty else { return "Credential projections: none." }
        let summary = projections
            .map { "\($0.displayName) mounted \($0.access == .readOnly ? "read-only" : "read-write") at \($0.containerPath)" }
            .joined(separator: "; ")
        return "Credential projections: \(summary)."
    }
}
