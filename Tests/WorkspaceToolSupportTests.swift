import Foundation
import Testing
@testable import WorkspaceToolSupport

@Suite("Workspace Tool Support", .serialized)
struct WorkspaceToolSupportTests {
    @Test("Workspace tool configuration decodes Docker mounts from environment")
    func workspaceToolConfigurationDecodesEnvironment() throws {
        let mountsJSON = """
        [{"hostPath":"/tmp/workspace","containerPath":"/workspace","access":"rw","role":"workspace"}]
        """
        let containerEnvironmentJSON = """
        {"CLOUDSDK_CONFIG":"/root/.config/gcloud","GOOGLE_APPLICATION_CREDENTIALS":"/root/.config/gcloud/application_default_credentials.json"}
        """

        let configuration = try WorkspaceToolConfiguration.fromEnvironment([
            "ASTRA_WORKSPACE_DOCKER_IMAGE": "astra/workspace:latest",
            "ASTRA_WORKSPACE_DOCKER_CONTAINER": "astra-task-run",
            "ASTRA_WORKSPACE_DOCKER_WORKDIR": "/workspace",
            "ASTRA_WORKSPACE_DOCKER_NETWORK": "bridge",
            "ASTRA_WORKSPACE_DOCKER_MOUNTS": mountsJSON,
            "ASTRA_WORKSPACE_DOCKER_ENV": containerEnvironmentJSON,
            "ASTRA_WORKSPACE_TASK_ID": "task-1",
            "ASTRA_WORKSPACE_RUN_ID": "run-1",
            "DOCKER_CONFIG": "/tmp/workspace/.astra/tasks/task-1/.runtime/docker-client/run-1",
            "ASTRA_WORKSPACE_DIAGNOSTICS_HOST": "/tmp/workspace/.astra/tasks/task-1/diagnostics",
            "ASTRA_WORKSPACE_SUBAGENT_PARENT_ID": "parent-task"
        ])

        #expect(configuration.dockerExecutable == "docker")
        #expect(configuration.image == "astra/workspace:latest")
        #expect(configuration.containerName == "astra-task-run")
        #expect(configuration.mounts == [
            WorkspaceDockerMount(hostPath: "/tmp/workspace", containerPath: "/workspace", access: "rw", role: "workspace")
        ])
        #expect(configuration.containerEnvironment["CLOUDSDK_CONFIG"] == "/root/.config/gcloud")
        #expect(configuration.containerEnvironment["GOOGLE_APPLICATION_CREDENTIALS"] == "/root/.config/gcloud/application_default_credentials.json")
        #expect(configuration.jobRootHostPath == "/tmp/workspace/.astra/tasks/task-1/jobs")
        #expect(configuration.jobRootContainerPath == "/workspace/.astra/tasks/task-1/jobs")
        #expect(configuration.dockerClientConfigPath == "/tmp/workspace/.astra/tasks/task-1/.runtime/docker-client/run-1")
        #expect(configuration.diagnosticsHostPath == "/tmp/workspace/.astra/tasks/task-1/diagnostics")
        #expect(configuration.subagentParentID == "parent-task")
        let path = try #require(configuration.containerEnvironment["PATH"])
        let pathComponents = path.split(separator: ":").map(String.init)
        #expect(pathComponents.contains("/opt/workspace/.venv/bin"))
        #expect(!pathComponents.contains("/workspace/.venv/bin"))
    }

    @Test("Workspace command path mapper rejects ambiguous mounted host paths")
    func workspaceCommandPathMapperRejectsAmbiguousMountedHostPaths() throws {
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "docker",
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(
                    hostPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake",
                    containerPath: "/workspace",
                    access: "rw",
                    role: "workspace"
                ),
                WorkspaceDockerMount(
                    hostPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake",
                    containerPath: "/project",
                    access: "rw",
                    role: "workspace"
                )
            ]
        )

        let resolution = configuration.containerCommand(
            for: "cat /Users/alvaro1/Documents/Coral/Code/starr-data-lake/dbt_project.yml"
        )

        #expect(resolution.command.contains("/Users/alvaro1/Documents/Coral/Code/starr-data-lake"))
        #expect(resolution.errorMessage?.contains("maps to more than one Docker container path") == true)
        #expect(resolution.errorMessage?.contains("/workspace") == true)
        #expect(resolution.errorMessage?.contains("/project") == true)
    }

    @Test("Workspace command path mapper rewrites mounted host paths")
    func workspaceCommandPathMapperRewritesMountedHostPaths() throws {
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "docker",
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(
                    hostPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake",
                    containerPath: "/workspace",
                    access: "rw",
                    role: "workspace"
                )
            ]
        )

        let resolution = configuration.containerCommand(
            for: "cd /Users/alvaro1/Documents/Coral/Code/starr-data-lake && cat dbt_project.yml"
        )

        #expect(resolution.command == "cd /workspace && cat dbt_project.yml")
        #expect(resolution.errorMessage == nil)
        #expect(resolution.mappedPaths == [
            WorkspaceCommandPathMapping(
                hostPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake",
                containerPath: "/workspace"
            )
        ])

        let nestedResolution = configuration.containerCommand(
            for: "cat /Users/alvaro1/Documents/Coral/Code/starr-data-lake/dbt_project.yml"
        )
        #expect(nestedResolution.command == "cat /workspace/dbt_project.yml")
        #expect(nestedResolution.errorMessage == nil)
    }

    @Test("Workspace command path mapper does not rewrite mount path substrings")
    func workspaceCommandPathMapperDoesNotRewriteMountPathSubstrings() throws {
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "docker",
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(
                    hostPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake",
                    containerPath: "/workspace",
                    access: "rw",
                    role: "workspace"
                )
            ]
        )

        let resolution = configuration.containerCommand(
            for: "cat /Users/alvaro1/Documents/Coral/Code/starr-data-lake-copy/dbt_project.yml"
        )

        #expect(resolution.command == "cat /Users/alvaro1/Documents/Coral/Code/starr-data-lake-copy/dbt_project.yml")
        #expect(resolution.errorMessage?.contains("host filesystem path") == true)
        #expect(resolution.errorMessage?.contains("starr-data-lake-copy") == true)
    }

    @Test("Workspace command path mapper rejects unmapped host paths")
    func workspaceCommandPathMapperRejectsUnmappedHostPaths() throws {
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "docker",
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: "/tmp/workspace", containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )

        let resolution = configuration.containerCommand(for: "cat /Users/alvaro1/.ssh/config")

        #expect(resolution.command == "cat /Users/alvaro1/.ssh/config")
        #expect(resolution.errorMessage?.contains("host filesystem path") == true)
        #expect(resolution.errorMessage?.contains("/Users/alvaro1/.ssh/config") == true)
        #expect(resolution.errorMessage?.contains("/tmp/workspace -> /workspace") == true)
    }

    @Test("Workspace command path mapper rejects macOS system paths inside Docker")
    func workspaceCommandPathMapperRejectsMacOSSystemPathsInsideDocker() throws {
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "docker",
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: "/tmp/workspace", containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )

        let libraryResolution = configuration.containerCommand(
            for: "/Library/Developer/CommandLineTools/usr/bin/python3 --version"
        )
        #expect(libraryResolution.errorMessage?.contains("host filesystem path") == true)
        #expect(libraryResolution.errorMessage?.contains("/Library/Developer/CommandLineTools/usr/bin/python3") == true)

        let privateVarResolution = configuration.containerCommand(for: "sh /private/var/select/sh")
        #expect(privateVarResolution.errorMessage?.contains("host filesystem path") == true)
        #expect(privateVarResolution.errorMessage?.contains("/private/var/select/sh") == true)
    }

    @Test("Workspace command path mapper rejects host control-plane commands in Docker")
    func workspaceCommandPathMapperRejectsHostControlPlaneCommands() throws {
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "docker",
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(
                    hostPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake",
                    containerPath: "/workspace",
                    access: "rw",
                    role: "workspace"
                )
            ]
        )

        let resolution = configuration.containerCommand(
            for: "cd /Users/alvaro1/Documents/Coral/Code/starr-data-lake && gh pr view 987 --comments"
        )

        #expect(resolution.command == "cd /workspace && gh pr view 987 --comments")
        #expect(resolution.errorMessage?.contains("host control-plane CLI 'gh'") == true)
        #expect(resolution.errorMessage?.contains("GitHub capability") == true)
        #expect(resolution.mappedPaths == [
            WorkspaceCommandPathMapping(
                hostPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake",
                containerPath: "/workspace"
            )
        ])

        let gcloud = configuration.containerCommand(for: "gcloud compute instances list")
        #expect(gcloud.errorMessage?.contains("host control-plane CLI 'gcloud'") == true)

        let ssh = configuration.containerCommand(for: "ssh deid-jsn-workbench 'hostname'")
        #expect(ssh.errorMessage?.contains("host control-plane CLI 'ssh'") == true)
    }

    @Test("Workspace MCP server exposes and runs workspace_shell")
    func workspaceMCPServerExposesAndRunsWorkspaceShell() throws {
        let executor = RecordingWorkspaceCommandExecutor(result: WorkspaceCommandResult(
            command: "pwd",
            exitCode: 0,
            stdout: "/workspace\n",
            stderr: ""
        ))
        let server = WorkspaceMCPServer(executor: executor)

        let initialize = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)))
        let initializeResult = try #require(initialize["result"] as? [String: Any])
        let serverInfo = try #require(initializeResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "astra-workspace")

        let list = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "workspace_shell")
        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        #expect(toolNames.isSuperset(of: [
            "workspace_shell",
            "workspace_job_start",
            "workspace_job_status",
            "workspace_job_tail",
            "workspace_job_cancel",
            "workspace_job_wait"
        ]))
        let description = try #require(tools.first?["description"] as? String)
        #expect(description.contains("using the image environment"))
        #expect(description.contains("workspace_job_start"))

        let call = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"workspace_shell","arguments":{"command":"pwd","timeout_seconds":7}}}"#)))
        let callResult = try #require(call["result"] as? [String: Any])
        #expect(callResult["isError"] as? Bool == false)
        let content = try #require(callResult["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("exit_code: 0"))
        #expect(text.contains("/workspace"))
        #expect(executor.commands == ["pwd"])
        #expect(executor.timeouts == [7])

        server.cleanup()
        #expect(executor.cleanedUp)
    }

    @Test("Workspace MCP server persists shell diagnostics")
    func workspaceMCPServerPersistsShellDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "docker",
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ],
            diagnosticsHostPath: diagnostics.path,
            subagentParentID: "parent-1"
        )
        let executor = RecordingWorkspaceCommandExecutor(result: WorkspaceCommandResult(
            command: "cat \(root.path)/README.md",
            exitCode: 2,
            stdout: "",
            stderr: "workspace command used a host filesystem path",
            routedCommand: "cat /workspace/README.md",
            workingDirectory: "/workspace"
        ))
        let server = WorkspaceMCPServer(
            executor: executor,
            diagnosticsRecorder: WorkspaceToolDiagnosticsRecorder(configuration: configuration)
        )

        _ = server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"workspace_shell","arguments":{"command":"cat /tmp/repo/README.md","timeout_seconds":7}}}"#)

        let log = diagnostics.appendingPathComponent("workspace_tool_activity.jsonl", isDirectory: false)
        let line = try #require(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last)
        let data = Data(line.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["toolName"] as? String == "workspace_shell")
        #expect(object["route"] as? String == "docker_workspace_mcp")
        #expect(object["mappedCommand"] as? String == "cat /workspace/README.md")
        #expect(object["workingDirectory"] as? String == "/workspace")
        #expect(object["exitCode"] as? Int == 2)
        #expect(object["stderrTail"] as? String == "workspace command used a host filesystem path")
        #expect(object["subagentParentID"] as? String == "parent-1")
    }

    @Test("Docker workspace executor starts container and execs workspace command through Docker")
    func dockerWorkspaceExecutorStartsContainerAndExecsCommandThroughDocker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-tool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        LOG='\(quotedLogPath)'
        printf '%s\\n' "$*" >> "$LOG"
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) printf 'env CLOUDSDK_CONFIG=%s\\n' "$CLOUDSDK_CONFIG" >> "$LOG"; printf 'env DOCKER_CONFIG=%s\\n' "$DOCKER_CONFIG" >> "$LOG"; printf 'env PATH=%s\\n' "$PATH" >> "$LOG"; echo container-id; exit 0 ;;
          exec) echo workspace-output; echo workspace-error >&2; exit 0 ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        let dockerConfig = root.appendingPathComponent("docker-client", isDirectory: true)
        try FileManager.default.createDirectory(at: dockerConfig, withIntermediateDirectories: true)

        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace"),
                WorkspaceDockerMount(hostPath: root.appendingPathComponent("gcloud").path, containerPath: "/root/.config/gcloud", access: "ro", role: "credential")
            ],
            containerEnvironment: [
                "CLOUDSDK_CONFIG": "/root/.config/gcloud",
                "GOOGLE_APPLICATION_CREDENTIALS": "/root/.config/gcloud/application_default_credentials.json"
            ],
            dockerClientConfigPath: dockerConfig.path
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)

        let result = executor.run(command: "echo ok", timeoutSeconds: 5)
        executor.cleanup()

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("workspace-output"))
        #expect(result.stderr.contains("workspace-error"))
        let logLines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(logLines.contains("inspect -f {{.State.Running}} astra-test"))
        #expect(logLines.contains("rm -f astra-test"))
        let runLine = try #require(logLines.first { $0.hasPrefix("run --rm -d --name astra-test") })
        #expect(runLine.hasSuffix("astra/workspace:latest sh -c while :; do sleep 3600; done"))
        #expect(logLines.contains { $0.contains("--volume \(root.path):/workspace:rw") })
        #expect(logLines.contains { $0.contains("--volume \(root.appendingPathComponent("gcloud").path):/root/.config/gcloud:ro") })
        #expect(runLine.contains("--env CLOUDSDK_CONFIG"))
        #expect(runLine.contains("--env GOOGLE_APPLICATION_CREDENTIALS"))
        #expect(runLine.contains("--env PATH=/opt/\(root.lastPathComponent)/.venv/bin"))
        #expect(!runLine.contains("GOOGLE_APPLICATION_CREDENTIALS=/root/.config/gcloud/application_default_credentials.json"))
        #expect(logLines.contains("env CLOUDSDK_CONFIG=/root/.config/gcloud"))
        let pathLine = try #require(logLines.first { $0.hasPrefix("env PATH=") })
        #expect(!pathLine.contains("/opt/\(root.lastPathComponent)/.venv/bin"))
        #expect(!pathLine.contains("/workspace/.venv/bin"))
        #expect(logLines.contains { $0.contains("DOCKER_CONFIG=\(dockerConfig.path)") })
        #expect(FileManager.default.fileExists(atPath: dockerConfig.appendingPathComponent("config.json").path))
        #expect(logLines.contains("exec -i --workdir /workspace astra-test sh -c echo ok"))
        #expect(!logLines.contains { $0.contains(" sh -lc ") })
        #expect(logLines.contains("stop astra-test"))
    }

    @Test("Docker workspace executor maps host workspace path before exec")
    func dockerWorkspaceExecutorMapsHostWorkspacePathBeforeExec() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-path-map-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let hostWorkspace = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: hostWorkspace, withIntermediateDirectories: true)
        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        LOG='\(quotedLogPath)'
        printf '%s\\n' "$*" >> "$LOG"
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec) echo mapped; exit 0 ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-map",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: hostWorkspace.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)

        let result = executor.run(command: "cd \(hostWorkspace.path) && pwd", timeoutSeconds: 5)
        executor.cleanup()

        #expect(result.exitCode == 0)
        let logText = try String(contentsOf: log, encoding: .utf8)
        #expect(logText.contains("exec -i --workdir /workspace astra-test-map sh -c cd /workspace && pwd"))
        #expect(!logText.contains("cd \(hostWorkspace.path)"))
    }

    @Test("Docker workspace executor rejects unmapped host path before starting container")
    func dockerWorkspaceExecutorRejectsUnmappedHostPathBeforeStartingContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-path-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        exit 99
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-reject",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)

        let result = executor.run(command: "cat /Users/alvaro1/.ssh/config", timeoutSeconds: 5)

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("not valid inside the Docker workspace"))
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test("Docker workspace executor rejects host control-plane command before starting container")
    func dockerWorkspaceExecutorRejectsHostControlPlaneCommandBeforeStartingContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-plane-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        exit 99
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let hostWorkspace = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: hostWorkspace, withIntermediateDirectories: true)
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-plane-reject",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: hostWorkspace.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)

        let result = executor.run(command: "cd \(hostWorkspace.path) && gh pr view 987 --comments", timeoutSeconds: 5)

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("host control-plane CLI 'gh'"))
        #expect(result.stderr.contains("GitHub capability"))
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test("Docker workspace shell rejects long-running project commands before starting container")
    func dockerWorkspaceShellRejectsLongRunningProjectCommandsBeforeStartingContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-long-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        exit 99
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-long-reject",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)

        let result = executor.run(command: "dbt build --select +death --full-refresh", timeoutSeconds: 120)

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("workspace_shell received a long-running project command"))
        #expect(result.stderr.contains("workspace_job_start"))
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test("Docker workspace shell rejects overly long synchronous timeout before starting container")
    func dockerWorkspaceShellRejectsLongSynchronousTimeoutBeforeStartingContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-timeout-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        LOG='\(quotedLogPath)'
        printf '%s\\n' "$*" >> "$LOG"
        exit 99
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-timeout-reject",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)

        let result = executor.run(command: "python - <<'PY'\nprint('ok')\nPY", timeoutSeconds: 600)

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("workspace_shell is limited to short checks"))
        #expect(result.stderr.contains("workspace_job_start"))
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test("Workspace MCP server exposes durable job tools")
    func workspaceMCPServerExposesDurableJobTools() throws {
        let executor = RecordingWorkspaceCommandExecutor(result: WorkspaceCommandResult(
            command: "pwd",
            exitCode: 0,
            stdout: "/workspace\n",
            stderr: ""
        ))
        let jobManager = RecordingWorkspaceJobManager()
        let server = WorkspaceMCPServer(executor: executor, jobManager: jobManager)

        let start = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"workspace_job_start","arguments":{"command":"dbt build --select +death","timeout_seconds":3600,"label":"dbt death","progress_probe":"dbt"}}}"#)))
        let startText = try resultText(start)
        #expect(startText.contains("job_id: job-1"))
        #expect(startText.contains("status: running"))
        #expect(jobManager.startedCommands == ["dbt build --select +death"])
        #expect(jobManager.startedLabels == ["dbt death"])
        #expect(jobManager.startedProgressProbes == ["dbt"])

        let status = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"workspace_job_status","arguments":{"job_id":"job-1"}}}"#)))
        #expect(try resultText(status).contains("status: running"))

        let tail = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"workspace_job_tail","arguments":{"job_id":"job-1","stream":"stderr","lines":20}}}"#)))
        #expect(try resultText(tail).contains("stream: stderr"))

        let wait = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"workspace_job_wait","arguments":{"job_id":"job-1","max_wait_seconds":1}}}"#)))
        #expect(try resultText(wait).contains("status: running"))
        #expect(jobManager.waitTimeouts == [1])

        let cancel = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"workspace_job_cancel","arguments":{"job_id":"job-1"}}}"#)))
        #expect(try resultText(cancel).contains("status: cancelled"))
    }

    @Test("Workspace job wait caps provider wait windows")
    func workspaceJobWaitCapsProviderWaitWindows() throws {
        let executor = RecordingWorkspaceCommandExecutor(result: WorkspaceCommandResult(
            command: "pwd",
            exitCode: 0,
            stdout: "/workspace\n",
            stderr: ""
        ))
        let jobManager = RecordingWorkspaceJobManager()
        let server = WorkspaceMCPServer(executor: executor, jobManager: jobManager)

        let wait = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"workspace_job_wait","arguments":{"job_id":"job-1","max_wait_seconds":3600}}}"#)))

        #expect(try resultText(wait).contains("status: running"))
        #expect(jobManager.waitTimeouts == [30])
    }

    @Test("Docker workspace job manager starts detached durable job")
    func dockerWorkspaceJobManagerStartsDetachedDurableJob() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-job-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        LOG='\(quotedLogPath)'
        printf '%s\\n' "$*" >> "$LOG"
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec) exit 0 ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-job",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-2",
            runID: "run-2",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ],
            jobRootHostPath: jobRoot.path,
            jobRootContainerPath: "/workspace/jobs"
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
        let manager = DockerWorkspaceJobManager(configuration: configuration, executor: executor)

        let job = manager.start(
            command: "printf started && sleep 60",
            timeoutSeconds: 7200,
            label: "long validation",
            progressProbe: "generic-log"
        )
        executor.cleanup()

        #expect(job.status == .running)
        let jobDirectory = jobRoot.appendingPathComponent(job.jobID, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: jobDirectory.appendingPathComponent("job.json").path))
        #expect(FileManager.default.fileExists(atPath: jobDirectory.appendingPathComponent("command.sh").path))
        #expect(try String(contentsOf: jobDirectory.appendingPathComponent("command.sh"), encoding: .utf8).contains("sleep 60"))
        let logLines = try String(contentsOf: log, encoding: .utf8)
        #expect(logLines.contains("exec -d --workdir /workspace astra-test-job sh -c"))
        #expect(logLines.contains("/workspace/jobs/\(job.jobID)"))
        #expect(logLines.contains("timeout_seconds=7200"))
        #expect(logLines.contains("status=timed_out; code=124"))

        try #"{"status":"succeeded","exitCode":0,"completedAt":"2026-06-24T12:00:00Z"}"#
            .write(to: jobDirectory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        try "ok\n".write(to: jobDirectory.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)
        let completed = manager.status(jobID: job.jobID)
        #expect(completed.status == .succeeded)
        #expect(completed.exitCode == 0)
        #expect(manager.tail(jobID: job.jobID, stream: "stdout", lines: 10).text.contains("ok"))
    }

    @Test("Managed job tail derives log paths from trusted job directory")
    func managedJobTailDerivesLogPathsFromTrustedJobDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-job-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let outside = root.appendingPathComponent("host-secret.txt", isDirectory: false)
        try "HOST_SECRET_FROM_OUTSIDE_JOB_DIR\n".write(to: outside, atomically: true, encoding: .utf8)

        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let store = WorkspaceManagedJobStore(rootPath: jobRoot.path)
        var record = try store.create(
            command: "printf safe",
            timeoutSeconds: nil,
            label: nil,
            progressProbe: nil,
            runtime: "docker"
        )
        let jobDirectory = jobRoot.appendingPathComponent(record.jobID, isDirectory: true)
        try "SAFE_STDOUT\n".write(to: jobDirectory.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)
        try "SAFE_STDERR\n".write(to: jobDirectory.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)

        record.stdoutLogPath = outside.path
        record.stderrLogPath = outside.path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: jobDirectory.appendingPathComponent("job.json"), options: [.atomic])

        let stdout = try store.tail(jobID: record.jobID, stream: "stdout", lines: 10)
        let stderr = try store.tail(jobID: record.jobID, stream: "stderr", lines: 10)

        #expect(stdout.text.contains("SAFE_STDOUT"))
        #expect(stderr.text.contains("SAFE_STDERR"))
        #expect(!stdout.text.contains("HOST_SECRET_FROM_OUTSIDE_JOB_DIR"))
        #expect(!stderr.text.contains("HOST_SECRET_FROM_OUTSIDE_JOB_DIR"))
    }

    @Test("Docker workspace job manager maps host workspace path before persisting command")
    func dockerWorkspaceJobManagerMapsHostWorkspacePathBeforePersistingCommand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-job-map-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let hostWorkspace = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: hostWorkspace, withIntermediateDirectories: true)
        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        LOG='\(quotedLogPath)'
        printf '%s\\n' "$*" >> "$LOG"
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec) exit 0 ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-job-map",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-3",
            runID: "run-3",
            mounts: [
                WorkspaceDockerMount(hostPath: hostWorkspace.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ],
            jobRootHostPath: jobRoot.path,
            jobRootContainerPath: "/workspace/jobs"
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
        let manager = DockerWorkspaceJobManager(configuration: configuration, executor: executor)

        let job = manager.start(
            command: "cd \(hostWorkspace.path) && dbt build",
            timeoutSeconds: 3600,
            label: "dbt",
            progressProbe: "dbt"
        )
        executor.cleanup()

        #expect(job.status == .running)
        #expect(job.command == "cd /workspace && dbt build")
        let commandPath = jobRoot
            .appendingPathComponent(job.jobID, isDirectory: true)
            .appendingPathComponent("command.sh", isDirectory: false)
            .path
        let commandText = try String(contentsOfFile: commandPath, encoding: .utf8)
        #expect(commandText.contains("cd /workspace && dbt build"))
        #expect(!commandText.contains(hostWorkspace.path))
    }

    @Test("Workspace MCP mixed Docker workflow runs shell then starts durable job")
    func workspaceMCPMixedDockerWorkflowRunsShellThenStartsDurableJob() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-mixed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        LOG='\(quotedLogPath)'
        printf '%s\\n' "$*" >> "$LOG"
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec)
            if [ "$2" = "-d" ]; then exit 0; fi
            echo /usr/local/bin/sqlfmt
            echo sqlfmt 0.1.0
            exit 0
            ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let jobRoot = root.appendingPathComponent(".astra/tasks/task-4/jobs", isDirectory: true)
        let diagnostics = root.appendingPathComponent(".astra/tasks/task-4/diagnostics", isDirectory: true)
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test-mixed",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-4",
            runID: "run-4",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ],
            jobRootHostPath: jobRoot.path,
            jobRootContainerPath: "/workspace/.astra/tasks/task-4/jobs",
            diagnosticsHostPath: diagnostics.path
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
        let manager = DockerWorkspaceJobManager(configuration: configuration, executor: executor)
        let server = WorkspaceMCPServer(
            executor: executor,
            jobManager: manager,
            diagnosticsRecorder: WorkspaceToolDiagnosticsRecorder(configuration: configuration)
        )

        let shell = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_shell","arguments":{"command":"command -v sqlfmt && sqlfmt --version","timeout_seconds":10}}}"#)))
        #expect(try resultText(shell).contains("sqlfmt 0.1.0"))

        let startLine = """
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workspace_job_start","arguments":{"command":"cd \(root.path) && dbt build --select +death","timeout_seconds":7200,"label":"dbt death","progress_probe":"dbt"}}}
        """
        let start = try parseJSON(try #require(server.handleLine(startLine)))
        let startText = try resultText(start)
        #expect(startText.contains("status: running"))
        #expect(startText.contains("command: cd /workspace && dbt build --select +death"))
        executor.cleanup()

        let logText = try String(contentsOf: log, encoding: .utf8)
        #expect(logText.contains("exec -i --workdir /workspace astra-test-mixed sh -c command -v sqlfmt && sqlfmt --version"))
        #expect(logText.contains("exec -d --workdir /workspace astra-test-mixed sh -c"))

        let activity = try String(
            contentsOf: diagnostics.appendingPathComponent("workspace_tool_activity.jsonl", isDirectory: false),
            encoding: .utf8
        )
        let records = try activity
            .split(separator: "\n")
            .map { line -> [String: Any] in
                try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        #expect(records.contains { $0["toolName"] as? String == "workspace_shell" })
        #expect(records.contains {
            $0["toolName"] as? String == "workspace_job_start" &&
                $0["mappedCommand"] as? String == "cd /workspace && dbt build --select +death"
        })
    }

    @Test("Docker workspace executor revalidates a started container before each command")
    func dockerWorkspaceExecutorRevalidatesStartedContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-tool-revalidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let inspectCount = root.appendingPathComponent("inspect.count")
        try """
        #!/bin/sh
        log_path="\(log.path)"
        count_path="\(inspectCount.path)"
        printf '%s\\n' "$*" >> "$log_path"
        case "$1" in
          inspect)
            count=0
            if [ -f "$count_path" ]; then count="$(cat "$count_path")"; fi
            count=$((count + 1))
            printf '%s' "$count" > "$count_path"
            if [ "$count" -eq 1 ]; then exit 1; fi
            printf 'false\\n'
            exit 0
            ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec) echo workspace-output; exit 0 ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let executor = DockerWorkspaceCommandExecutor(configuration: dockerConfiguration(docker: docker, root: root))

        let first = executor.run(command: "echo one", timeoutSeconds: 5)
        let second = executor.run(command: "echo two", timeoutSeconds: 5)
        executor.cleanup()

        #expect(first.exitCode == 0)
        #expect(second.exitCode == 0)
        let logLines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(logLines.filter { $0 == "inspect -f {{.State.Running}} astra-test" }.count == 2)
        #expect(logLines.filter { $0 == "rm -f astra-test" }.count == 2)
        #expect(logLines.filter { $0.hasPrefix("run --rm -d --name astra-test") }.count == 2)
        #expect(logLines.contains("exec -i --workdir /workspace astra-test sh -c echo one"))
        #expect(logLines.contains("exec -i --workdir /workspace astra-test sh -c echo two"))
    }

    @Test("Docker invocation uses direct executable paths only for absolute paths")
    func dockerInvocationUsesDirectExecutablePathsOnlyForAbsolutePaths() {
        #expect(DockerProcessInvocation.resolve(
            dockerExecutable: "/usr/local/bin/docker",
            arguments: ["inspect"]
        ) == DockerProcessInvocation(
            executablePath: "/usr/local/bin/docker",
            arguments: ["inspect"]
        ))
        #expect(DockerProcessInvocation.resolve(
            dockerExecutable: "docker",
            arguments: ["inspect"]
        ) == DockerProcessInvocation(
            executablePath: "/usr/bin/env",
            arguments: ["docker", "inspect"]
        ))
        #expect(DockerProcessInvocation.resolve(
            dockerExecutable: "./docker",
            arguments: ["inspect"]
        ) == DockerProcessInvocation(
            executablePath: "/usr/bin/env",
            arguments: ["./docker", "inspect"]
        ))
        #expect(DockerProcessInvocation.resolve(
            dockerExecutable: "usr/local/bin/docker",
            arguments: ["inspect"]
        ) == DockerProcessInvocation(
            executablePath: "/usr/bin/env",
            arguments: ["usr/local/bin/docker", "inspect"]
        ))
    }

    private func parseJSON(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func resultText(_ object: [String: Any]) throws -> String {
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func dockerConfiguration(docker: URL, root: URL) -> WorkspaceToolConfiguration {
        WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-test",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-1",
            runID: "run-1",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ]
        )
    }
}

private final class RecordingWorkspaceCommandExecutor: WorkspaceCommandExecutor {
    private let result: WorkspaceCommandResult
    private(set) var commands: [String] = []
    private(set) var timeouts: [TimeInterval] = []
    private(set) var cleanedUp = false

    init(result: WorkspaceCommandResult) {
        self.result = result
    }

    func run(command: String, timeoutSeconds: TimeInterval) -> WorkspaceCommandResult {
        commands.append(command)
        timeouts.append(timeoutSeconds)
        return result
    }

    func cleanup() {
        cleanedUp = true
    }
}

private final class RecordingWorkspaceJobManager: WorkspaceJobManaging {
    private(set) var startedCommands: [String] = []
    private(set) var startedLabels: [String?] = []
    private(set) var startedProgressProbes: [String?] = []
    private(set) var waitTimeouts: [TimeInterval] = []
    private var cancelled = false

    func start(
        command: String,
        timeoutSeconds _: TimeInterval?,
        label: String?,
        progressProbe: String?
    ) -> WorkspaceManagedJobRecord {
        startedCommands.append(command)
        startedLabels.append(label)
        startedProgressProbes.append(progressProbe)
        return record(status: .running)
    }

    func status(jobID _: String) -> WorkspaceManagedJobRecord {
        record(status: cancelled ? .cancelled : .running)
    }

    func tail(jobID: String, stream: String, lines _: Int) -> WorkspaceManagedJobTail {
        WorkspaceManagedJobTail(jobID: jobID, stream: stream, text: "job output")
    }

    func cancel(jobID _: String) -> WorkspaceManagedJobRecord {
        cancelled = true
        return record(status: .cancelled)
    }

    func wait(jobID _: String, timeoutSeconds: TimeInterval) -> WorkspaceManagedJobRecord {
        waitTimeouts.append(timeoutSeconds)
        return record(status: cancelled ? .cancelled : .running)
    }

    private func record(status: WorkspaceManagedJobStatus) -> WorkspaceManagedJobRecord {
        let now = Date(timeIntervalSince1970: 1_782_300_000)
        return WorkspaceManagedJobRecord(
            jobID: "job-1",
            command: "dbt build --select +death",
            label: "dbt death",
            progressProbe: "dbt",
            runtime: "docker",
            status: status,
            createdAt: now,
            startedAt: now,
            updatedAt: now,
            stdoutLogPath: "/tmp/job/stdout.log",
            stderrLogPath: "/tmp/job/stderr.log",
            heartbeatPath: "/tmp/job/heartbeat.json",
            resultPath: "/tmp/job/result.json"
        )
    }
}
