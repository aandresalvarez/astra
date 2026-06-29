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
                Run project commands with the ASTRA workspace MCP tool; it executes inside the Docker container. Use `workspace_shell` only for short checks; synchronous shell calls are intentionally bounded and will reject long-running build/test/dbt commands. For long-running commands such as `dbt build`, `docker build`, test suites, migrations, or cloud operations, use `workspace_job_start`, then inspect progress with `workspace_job_status`, `workspace_job_tail`, and short `workspace_job_wait` polling windows. Claude-style and Codex runtimes call these as `mcp__astra_workspace__<tool>`; the short shell tool is `mcp__astra_workspace__workspace_shell`, and durable jobs start with `mcp__astra_workspace__workspace_job_start`. GitHub Copilot CLI displays the same tools as `astra_workspace-<tool>`, including `astra_workspace-workspace_shell` and `astra_workspace-workspace_job_start`. Do not use native host Bash for project commands in this workspace. Host workspace files are bind-mounted into the container; use the container paths above while running commands and report host paths in final summaries when relevant.
                Routing contract: provider reasoning runs on host macOS, workspace shell commands run in Docker, and host control-plane actions such as GitHub PR metadata, Jira, read-only Google Cloud checks, SSH, browser, and Keychain access must use ASTRA-exposed host capabilities when available. Use `mcp__astra_host__github`, `mcp__astra_host__gcloud`, `mcp__astra_host__bq`, `mcp__astra_host__ssh`, or `mcp__astra_host__jira` for host control-plane work; GitHub Copilot CLI may display these as `astra_host-github`, `astra_host-gcloud`, `astra_host-bq`, `astra_host-ssh`, and `astra_host-jira`. Do not ask a subagent to "run locally" or to use native host Bash to escape this routing; subagents must use the same Docker workspace MCP tools for project commands and ASTRA host-control MCP tools for host services. If a host control-plane capability is missing, report that capability as missing instead of trying to run a host CLI from the Docker workspace.
                Path mapping: inside workspace MCP tools, the host workspace path is mounted at \(containerCodeDir). Do not run `cd /Users/...` or use other host filesystem paths inside Docker commands; use \(containerCodeDir) and the container task folder above.
                Prefer tools installed in the image environment. Check tools by name from the container PATH, such as `command -v dbt && dbt --version`, through the ASTRA workspace MCP tool. Start long validations as managed jobs so ASTRA can track heartbeats, logs, and result files while the provider is quiet.
                When checking cloud-backed tools, verify credential readiness from inside the container before declaring GCP ready: inspect `CLOUDSDK_CONFIG`, `GOOGLE_APPLICATION_CREDENTIALS`, and whether the credentials file exists, then run a non-destructive auth check such as `gcloud auth application-default print-access-token --quiet` only if gcloud is installed. If this section says `Credential projections: none.`, report GCP credentials as not projected instead of inferring readiness from dbt parse or project files.
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
