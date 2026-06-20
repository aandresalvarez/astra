import Foundation
import Testing
@testable import WorkspaceToolSupport

@Suite("Workspace Tool Support")
struct WorkspaceToolSupportTests {
    @Test("Workspace tool configuration decodes Docker mounts from environment")
    func workspaceToolConfigurationDecodesEnvironment() throws {
        let mountsJSON = """
        [{"hostPath":"/tmp/workspace","containerPath":"/workspace","access":"rw","role":"workspace"}]
        """

        let configuration = try WorkspaceToolConfiguration.fromEnvironment([
            "ASTRA_WORKSPACE_DOCKER_IMAGE": "astra/workspace:latest",
            "ASTRA_WORKSPACE_DOCKER_CONTAINER": "astra-task-run",
            "ASTRA_WORKSPACE_DOCKER_WORKDIR": "/workspace",
            "ASTRA_WORKSPACE_DOCKER_NETWORK": "bridge",
            "ASTRA_WORKSPACE_DOCKER_MOUNTS": mountsJSON,
            "ASTRA_WORKSPACE_TASK_ID": "task-1",
            "ASTRA_WORKSPACE_RUN_ID": "run-1"
        ])

        #expect(configuration.dockerExecutable == "docker")
        #expect(configuration.image == "astra/workspace:latest")
        #expect(configuration.containerName == "astra-task-run")
        #expect(configuration.mounts == [
            WorkspaceDockerMount(hostPath: "/tmp/workspace", containerPath: "/workspace", access: "rw", role: "workspace")
        ])
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
        let description = try #require(tools.first?["description"] as? String)
        #expect(description.contains("using the image environment"))
        #expect(description.contains("avoid host-created virtual environments"))

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

    @Test("Docker workspace executor starts container and execs workspace command through Docker")
    func dockerWorkspaceExecutorStartsContainerAndExecsCommandThroughDocker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-workspace-tool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec) echo workspace-output; echo workspace-error >&2; exit 0 ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        setenv("FAKE_DOCKER_LOG", log.path, 1)
        defer { unsetenv("FAKE_DOCKER_LOG") }

        let configuration = WorkspaceToolConfiguration(
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
        #expect(logLines.contains("exec -i --workdir /workspace astra-test sh -c echo ok"))
        #expect(!logLines.contains { $0.contains(" sh -lc ") })
        #expect(logLines.contains("stop astra-test"))
    }

    private func parseJSON(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
