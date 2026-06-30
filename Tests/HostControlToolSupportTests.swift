import Foundation
import Testing
@testable import HostControlToolSupport
@testable import WorkspaceToolSupport

@Suite("Host Control Tool Support", .serialized)
struct HostControlToolSupportTests {
    @Test("Host control MCP runs fake host tools and redacts connector secrets")
    func hostControlMCPRunsFakeHostToolsAndRedactsConnectorSecrets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-control-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let gh = try fakeExecutable(named: "gh", root: root, log: log, stdout: "gh:$*\nsecret:$JIRA_TOKEN_ENV")
        let gcloud = try fakeExecutable(named: "gcloud", root: root, log: log, stdout: "gcloud:$*")
        let bq = try fakeExecutable(named: "bq", root: root, log: log, stdout: "bq:$*")
        let ssh = try fakeExecutable(named: "ssh", root: root, log: log, stdout: "ssh:$*")
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"baseURL":"JIRA_BASE_URL","JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            githubExecutable: gh.path,
            gcloudExecutable: gcloud.path,
            bigQueryExecutable: bq.path,
            sshExecutable: ssh.path,
            allowedSSHAliases: ["deid-jsn-workbench"],
            diagnosticsHostPath: diagnostics.path,
            taskID: "task-1",
            runID: "run-1",
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_BASE_URL": "https://example.atlassian.net",
                "JIRA_EMAIL_ENV": "user@example.com",
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        )
        let server = HostControlMCPServer(
            configuration: configuration,
            diagnosticsRecorder: HostControlToolDiagnosticsRecorder(configuration: configuration)
        )

        let list = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        #expect(toolNames == ["github", "gcloud", "bq", "ssh", "jira"])

        let github = try call(server, id: 2, tool: "github", arguments: [
            "arguments": ["pr", "view", "123", "--comments"],
            "timeout_seconds": 5
        ])
        let githubText = try resultText(github)
        #expect(githubText.contains("gh:pr view 123 --comments"))
        #expect(githubText.contains("[redacted]"))
        #expect(!githubText.contains("super-secret-token"))

        let gcloudResult = try call(server, id: 3, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list", "--format=json"]
        ])
        #expect(try resultText(gcloudResult).contains("gcloud:compute instances list --format=json"))

        let bqResult = try call(server, id: 4, tool: "bq", arguments: [
            "arguments": ["ls", "project:dataset"]
        ])
        #expect(try resultText(bqResult).contains("bq:ls project:dataset"))

        let sshResult = try call(server, id: 5, tool: "ssh", arguments: [
            "alias": "deid-jsn-workbench",
            "remote_command": "hostname && uptime"
        ])
        #expect(try resultText(sshResult).contains("ssh:deid-jsn-workbench hostname && uptime"))

        let jira = try call(server, id: 6, tool: "jira", arguments: ["operation": "status"])
        let jiraText = try resultText(jira)
        #expect(jiraText.contains("ready: true"))
        #expect(jiraText.contains("api_token_present: true"))
        #expect(!jiraText.contains("super-secret-token"))

        let hostLog = try String(contentsOf: log, encoding: .utf8)
        #expect(hostLog.contains("gh pr view 123 --comments"))
        #expect(hostLog.contains("gcloud compute instances list --format=json"))
        #expect(hostLog.contains("bq ls project:dataset"))
        #expect(hostLog.contains("ssh deid-jsn-workbench hostname && uptime"))

        let diagnosticLog = diagnostics.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false)
        let diagnosticsText = try String(contentsOf: diagnosticLog, encoding: .utf8)
        #expect(diagnosticsText.contains(#""toolName":"github""#))
        #expect(diagnosticsText.contains(#""toolName":"jira""#))
        #expect(!diagnosticsText.contains("super-secret-token"))
    }

    @Test("Host and Docker mixed harness routes control-plane and workspace commands separately")
    func hostAndDockerMixedHarnessRoutesControlPlaneAndWorkspaceCommandsSeparately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-docker-mixed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let hostLog = root.appendingPathComponent("host.log", isDirectory: false)
        let gh = try fakeExecutable(named: "gh", root: root, log: hostLog, stdout: "gh:$*")
        let gcloud = try fakeExecutable(named: "gcloud", root: root, log: hostLog, stdout: "gcloud:$*")
        let ssh = try fakeExecutable(named: "ssh", root: root, log: hostLog, stdout: "ssh:$*")
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let hostDiagnostics = root.appendingPathComponent(".astra/tasks/task-5/diagnostics", isDirectory: true)
        let hostServer = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: gh.path,
                gcloudExecutable: gcloud.path,
                bigQueryExecutable: "bq",
                sshExecutable: ssh.path,
                allowedSSHAliases: ["deid-jsn-workbench"],
                diagnosticsHostPath: hostDiagnostics.path,
                taskID: "task-5",
                runID: "run-5",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_EMAIL_ENV": "user@example.com",
                    "JIRA_TOKEN_ENV": "secret-token"
                ]
            ),
            diagnosticsRecorder: HostControlToolDiagnosticsRecorder(configuration: HostControlToolConfiguration(
                diagnosticsHostPath: hostDiagnostics.path,
                taskID: "task-5",
                runID: "run-5",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_EMAIL_ENV": "user@example.com",
                    "JIRA_TOKEN_ENV": "secret-token"
                ]
            ))
        )

        _ = try call(hostServer, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123", "--comments"]])
        _ = try call(hostServer, id: 2, tool: "gcloud", arguments: ["arguments": ["compute", "instances", "list"]])
        _ = try call(hostServer, id: 3, tool: "ssh", arguments: ["alias": "deid-jsn-workbench", "remote_command": "uptime"])
        _ = try call(hostServer, id: 4, tool: "jira", arguments: ["operation": "status"])

        let docker = root.appendingPathComponent("docker", isDirectory: false)
        let dockerLog = root.appendingPathComponent("docker.log", isDirectory: false)
        let quotedDockerLogPath = dockerLog.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        LOG='\(quotedDockerLogPath)'
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

        let jobRoot = root.appendingPathComponent(".astra/tasks/task-5/jobs", isDirectory: true)
        let workspaceConfiguration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-mixed",
            workdir: "/workspace",
            network: "bridge",
            taskID: "task-5",
            runID: "run-5",
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ],
            jobRootHostPath: jobRoot.path,
            jobRootContainerPath: "/workspace/.astra/tasks/task-5/jobs",
            diagnosticsHostPath: hostDiagnostics.path
        )
        let executor = DockerWorkspaceCommandExecutor(configuration: workspaceConfiguration)
        let workspaceServer = WorkspaceMCPServer(
            executor: executor,
            jobManager: DockerWorkspaceJobManager(configuration: workspaceConfiguration, executor: executor),
            diagnosticsRecorder: WorkspaceToolDiagnosticsRecorder(configuration: workspaceConfiguration)
        )
        _ = try call(workspaceServer, id: 5, tool: "workspace_shell", arguments: [
            "command": "command -v sqlfmt && sqlfmt --version",
            "timeout_seconds": 10
        ])
        let start = try call(workspaceServer, id: 6, tool: "workspace_job_start", arguments: [
            "command": "cd \(root.path) && dbt build --select +death",
            "timeout_seconds": 7200,
            "label": "dbt death",
            "progress_probe": "dbt"
        ])
        #expect(try resultText(start).contains("command: cd /workspace && dbt build --select +death"))
        executor.cleanup()

        let hostLogText = try String(contentsOf: hostLog, encoding: .utf8)
        #expect(hostLogText.contains("gh pr view 123 --comments"))
        #expect(hostLogText.contains("gcloud compute instances list"))
        #expect(hostLogText.contains("ssh deid-jsn-workbench uptime"))

        let dockerLogText = try String(contentsOf: dockerLog, encoding: .utf8)
        #expect(dockerLogText.contains("exec -i --workdir /workspace astra-mixed sh -c command -v sqlfmt && sqlfmt --version"))
        #expect(dockerLogText.contains("exec -d --workdir /workspace astra-mixed sh -c"))
        #expect(!dockerLogText.contains("gh pr"))
        #expect(!dockerLogText.contains("gcloud compute"))
        #expect(!dockerLogText.contains("ssh deid-jsn-workbench"))

        let hostActivity = try String(
            contentsOf: hostDiagnostics.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false),
            encoding: .utf8
        )
        #expect(hostActivity.contains(#""route":"host_control_mcp""#))
        let workspaceActivity = try String(
            contentsOf: hostDiagnostics.appendingPathComponent("workspace_tool_activity.jsonl", isDirectory: false),
            encoding: .utf8
        )
        #expect(workspaceActivity.contains(#""route":"docker_workspace_mcp""#))
        let workspaceRecords = try workspaceActivity
            .split(separator: "\n")
            .map { line -> [String: Any] in
                try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        #expect(workspaceRecords.contains {
            $0["toolName"] as? String == "workspace_job_start"
                && $0["mappedCommand"] as? String == "cd /workspace && dbt build --select +death"
        })
    }

    @Test("Host control process tools clamp provider-selected timeouts")
    func hostControlProcessToolsClampProviderSelectedTimeouts() throws {
        let runner = CapturingHostControlProcessRunner()
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processRunner: runner
        )

        _ = try call(server, id: 1, tool: "github", arguments: [
            "arguments": ["pr", "view", "123"],
            "timeout_seconds": 7200
        ])

        #expect(runner.requests.map(\.timeoutSeconds) == [300])
    }

    @Test("Host control process tools normalize non-finite timeout inputs")
    func hostControlProcessToolsNormalizeNonFiniteTimeoutInputs() throws {
        let runner = CapturingHostControlProcessRunner()
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processRunner: runner,
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 42, outputByteLimit: 1024)
        )

        _ = try call(server, id: 1, tool: "github", arguments: [
            "arguments": ["pr", "view", "123"],
            "timeout_seconds": "nan"
        ])

        #expect(runner.requests.map(\.timeoutSeconds) == [42])
    }

    @Test("Host control process limits reject non-finite configured timeout caps")
    func hostControlProcessLimitsRejectNonFiniteConfiguredTimeoutCaps() {
        let limits = HostControlProcessLimits(maximumTimeoutSeconds: .nan, outputByteLimit: 1024)

        #expect(limits.maximumTimeoutSeconds == 300)
        #expect(limits.clampedTimeout(.nan) == 300)
    }

    @Test("Host control default process runner uses server process limits")
    func hostControlDefaultProcessRunnerUsesServerProcessLimits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-server-output-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let gh = root.appendingPathComponent("gh", isDirectory: false)
        try """
        #!/bin/sh
        dd if=/dev/zero bs=1024 count=16 2>/dev/null | tr '\\0' A
        printf 'TAIL_SENTINEL'
        exit 0
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: gh.path),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 64)
        )

        let response = try call(server, id: 1, tool: "github", arguments: [
            "arguments": ["pr", "view", "123"]
        ])
        let text = try resultText(response)

        #expect(text.contains("exit_code: 125"))
        #expect(text.contains("output_truncated: true"))
        #expect(text.contains("stdout_truncated: true"))
        #expect(text.contains("ASTRA truncated stdout after"))
        #expect(!text.contains("TAIL_SENTINEL"))
    }

    @Test("Host control process runner truncates excessive stdout before returning results")
    func hostControlProcessRunnerTruncatesExcessiveStdoutBeforeReturningResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-output-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("noisy", isDirectory: false)
        try """
        #!/bin/sh
        dd if=/dev/zero bs=1024 count=320 2>/dev/null | tr '\\0' A
        printf 'TAIL_SENTINEL'
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = HostControlProcessRunner().run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 10,
            environment: [:]
        )

        #expect(result.exitCode == 125)
        #expect(result.stdoutTruncated)
        #expect(result.stdout.contains("ASTRA truncated stdout after"))
        #expect(!result.stdout.contains("TAIL_SENTINEL"))
        #expect(Data(result.stdout.utf8).count < 270_000)
    }

    @Test("Host control process runner keeps truncation marker within tiny output limits")
    func hostControlProcessRunnerKeepsTruncationMarkerWithinTinyOutputLimits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-tiny-output-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = try customExecutable(named: "tiny-noisy", root: root, body: """
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        exit 0
        """)

        let result = HostControlProcessRunner(limits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 8)).run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 5,
            environment: [:]
        )

        #expect(result.exitCode == 125)
        #expect(result.stdoutTruncated)
        #expect(Data(result.stdout.utf8).count <= 8)
    }

    @Test("Host control process runner preserves safe output prefix before truncation marker")
    func hostControlProcessRunnerPreservesSafeOutputPrefixBeforeTruncationMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-safe-output-prefix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = try customExecutable(named: "prefix-noisy", root: root, body: """
        printf 'SAFE-PREFIX-0123456789'
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        exit 0
        """)

        let outputLimit = 640
        let result = HostControlProcessRunner(limits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: outputLimit)).run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 5,
            environment: [:]
        )

        #expect(result.exitCode == 125)
        #expect(result.stdoutTruncated)
        #expect(result.stdout.contains("SAFE-PREFIX-0123456789"))
        #expect(result.stdout.contains("ASTRA truncated stdout after \(outputLimit) bytes"))
        #expect(Data(result.stdout.utf8).count <= outputLimit)
    }

    @Test("Host control process runner clamps timeouts at the shared runner boundary")
    func hostControlProcessRunnerClampsTimeoutsAtSharedRunnerBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-runner-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = try customExecutable(named: "slow", root: root, body: """
        sleep 2
        printf 'finished'
        exit 0
        """)
        let started = Date()

        let result = HostControlProcessRunner(limits: HostControlProcessLimits(maximumTimeoutSeconds: 1, outputByteLimit: 1024)).run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 10,
            environment: [:]
        )

        #expect(result.timedOut)
        #expect(result.exitCode == 124)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(!result.stdout.contains("finished"))
    }

    @Test("Host control process runner uses monotonic deadlines and fail-closed pipe drain")
    func hostControlProcessRunnerUsesMonotonicDeadlinesAndFailClosedPipeDrain() throws {
        let source = try hostControlToolSource()
        let wait = try sourceSnippet(startingWith: "    private func waitForProcess(", endingBefore: "    private func dispatchInterval", in: source)
        let drain = try sourceSnippet(startingWith: "    private func drainPipe(", endingBefore: "private final class LockedFlag", in: source)
        let jira = try sourceSnippet(startingWith: "private final class BoundedJiraHTTPDelegate", endingBefore: "private final class JiraHTTPClient", in: source)

        #expect(wait.contains("DispatchTime.now()"))
        #expect(!wait.contains("Date()"))
        #expect(drain.contains("guard flags >= 0 else"))
        #expect(drain.contains("guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else"))
        #expect(drain.contains("stopReading(handle)"))
        #expect(jira.contains("BoundedProcessOutput(label: \"Jira response body\""))
        #expect(jira.contains("bodyTruncated = true"))
        #expect(source.contains("outputByteLimit: processLimits.outputByteLimit"))
    }

    @Test("Host control process runner force stops output limited processes promptly")
    func hostControlProcessRunnerForceStopsOutputLimitedProcessesPromptly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-runner-output-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = try customExecutable(named: "noisy", root: root, body: """
        trap '' TERM
        while :; do
          printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        done
        """)
        let started = Date()

        let result = HostControlProcessRunner(limits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 64)).run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 5,
            environment: [:]
        )

        #expect(result.exitCode == 125)
        #expect(result.stdoutTruncated)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test("Host control process runner does not wait on inherited pipes after exit")
    func hostControlProcessRunnerDoesNotWaitOnInheritedPipesAfterExit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-runner-inherited-pipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = try customExecutable(named: "detached-noisy-child", root: root, body: """
        (sleep 0.1; printf 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'; sleep 2) &
        exit 0
        """)
        let started = Date()

        let result = HostControlProcessRunner(limits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 32)).run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 5,
            environment: [:]
        )

        #expect(result.exitCode == 0)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test("Host control tool schemas describe the configured timeout cap")
    func hostControlToolSchemasDescribeConfiguredTimeoutCap() throws {
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 42, outputByteLimit: 1024)
        )

        let list = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])

        for tool in tools {
            let inputSchema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(inputSchema["properties"] as? [String: Any])
            let timeout = try #require(properties["timeout_seconds"] as? [String: Any])
            let description = try #require(timeout["description"] as? String)
            #expect(description.contains("Defaults to 42 seconds"))
            #expect(description.contains("capped at 42 seconds"))
            #expect(!description.contains("Defaults to 120 seconds"))
            #expect(!description.contains("300 seconds"))
        }
    }

    @Test("Host control tool schemas never describe non-finite timeout caps")
    func hostControlToolSchemasNeverDescribeNonFiniteTimeoutCaps() throws {
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: .nan, outputByteLimit: 1024)
        )

        let list = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])

        for tool in tools {
            let inputSchema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(inputSchema["properties"] as? [String: Any])
            let timeout = try #require(properties["timeout_seconds"] as? [String: Any])
            let description = try #require(timeout["description"] as? String)
            #expect(description.contains("capped at 300 seconds"))
            #expect(!description.lowercased().contains("nan"))
        }
    }

    @Test("Host control truncation does not reveal connector secret prefixes")
    func hostControlTruncationDoesNotRevealConnectorSecretPrefixes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-truncated-secret-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let gh = try customExecutable(named: "gh", root: root, body: """
        printf 'visible-prefix:'
        printf '%s' "$JIRA_TOKEN_ENV"
        printf ':hidden-tail'
        exit 0
        """)
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: gh.path,
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_TOKEN_ENV": "super-secret-token"
                ]
            ),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: "visible-prefix:super-secr".count)
        )

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let text = try resultText(response)

        #expect(text.contains("output_truncated: true"))
        #expect(!text.contains("super-secr"))
        #expect(!text.contains("super-secret-token"))
    }

    @Test("Host control redacts secret prefixes on both streams when either stream truncates")
    func hostControlRedactsSecretPrefixesOnBothStreamsWhenEitherStreamTruncates() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let runner = CapturingHostControlProcessRunner(result: HostControlCommandResult(
            command: "/usr/bin/gh",
            arguments: ["pr", "view", "123"],
            exitCode: 125,
            stdout: "stdout-prefix:super-secr",
            stderr: "stderr was truncated",
            stdoutTruncated: false,
            stderrTruncated: true
        ))
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: "/usr/bin/gh",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_TOKEN_ENV": "super-secret-token"
                ]
            ),
            processRunner: runner
        )

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let text = try resultText(response)

        #expect(text.contains("output_truncated: true"))
        #expect(!text.contains("super-secr"))
        #expect(!text.contains("super-secret-token"))
    }

    @Test("Host control redacts secret prefixes from timed-out output")
    func hostControlRedactsSecretPrefixesFromTimedOutOutput() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let runner = CapturingHostControlProcessRunner(result: HostControlCommandResult(
            command: "/usr/bin/gh",
            arguments: ["pr", "view", "123"],
            exitCode: 124,
            stdout: "timed-out-prefix:super-secr",
            stderr: "",
            timedOut: true
        ))
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: "/usr/bin/gh",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_TOKEN_ENV": "super-secret-token"
                ]
            ),
            processRunner: runner
        )

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let text = try resultText(response)

        #expect(text.contains("timed_out: true"))
        #expect(!text.contains("super-secr"))
        #expect(!text.contains("super-secret-token"))
    }

    @Test("Host control redacts long secret fragments without prefix enumeration")
    func hostControlRedactsLongSecretFragmentsWithoutPrefixEnumeration() throws {
        let longSecret = String(repeating: "s", count: 12_000) + "-tail"
        let leakedPrefix = String(longSecret.prefix(8_000))
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_TOKEN_ENV": longSecret
            ]
        )

        let redacted = configuration.redacted("prefix:\(leakedPrefix):suffix", includingSecretFragments: true)

        #expect(redacted.contains("prefix:[redacted]:suffix"))
        #expect(!redacted.contains(String(repeating: "s", count: 64)))
    }

    @Test("Host control redacts short secret prefixes at truncation boundaries")
    func hostControlRedactsShortSecretPrefixesAtTruncationBoundaries() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let runner = CapturingHostControlProcessRunner(result: HostControlCommandResult(
            command: "/usr/bin/gh",
            arguments: ["pr", "view", "123"],
            exitCode: 125,
            stdout: "visible-prefix:su\n[ASTRA truncated stdout after 17 bytes]\n",
            stderr: "",
            stdoutTruncated: true
        ))
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: "/usr/bin/gh",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_TOKEN_ENV": "super-secret-token"
                ]
            ),
            processRunner: runner
        )

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let text = try resultText(response)

        #expect(text.contains("visible-prefix:[redacted]"))
        #expect(!text.contains("visible-prefix:su"))
        #expect(!text.contains("super-secret-token"))
    }

    @Test("Host control reapplies output caps after secret prefix redaction")
    func hostControlReappliesOutputCapsAfterSecretPrefixRedaction() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let runner = CapturingHostControlProcessRunner(result: HostControlCommandResult(
            command: "/usr/bin/gh",
            arguments: ["pr", "view", "123"],
            exitCode: 125,
            stdout: String(repeating: "supe", count: 40),
            stderr: "",
            stdoutTruncated: true
        ))
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: "/usr/bin/gh",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_TOKEN_ENV": "super-secret-token"
                ]
            ),
            processRunner: runner,
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 96)
        )

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let stdout = try stdoutSection(in: resultText(response))

        #expect(stdout.utf8.count <= 96)
        #expect(stdout.contains("redacted"))
        #expect(!stdout.contains("supe"))
    }

    private func fakeExecutable(named name: String, root: URL, log: URL, stdout: String) throws -> URL {
        let executable = root.appendingPathComponent(name, isDirectory: false)
        let quotedLog = log.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        printf '\(name) %s\\n' "$*" >> '\(quotedLog)'
        printf '\(name):%s\\n' "$*"
        if [ '\(name)' = 'gh' ]; then printf 'secret:%s\\n' "$JIRA_TOKEN_ENV"; fi
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func customExecutable(named name: String, root: URL, body: String) throws -> URL {
        let executable = root.appendingPathComponent(name, isDirectory: false)
        try """
        #!/bin/sh
        \(body)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func call(_ server: HostControlMCPServer, id: Int, tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let request = try requestJSON(id: id, tool: tool, arguments: arguments)
        return try parseJSON(try #require(server.handleLine(request)))
    }

    private func call(_ server: WorkspaceMCPServer, id: Int, tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let request = try requestJSON(id: id, tool: tool, arguments: arguments)
        return try parseJSON(try #require(server.handleLine(request)))
    }

    private func requestJSON(id: Int, tool: String, arguments: [String: Any]) throws -> String {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": tool,
                "arguments": arguments
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
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

    private func stdoutSection(in text: String) throws -> String {
        let start = try #require(text.range(of: "stdout:\n"))
        let end = try #require(text.range(of: "\nstderr:", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    private func hostControlToolSource() throws -> String {
        let root = try repositoryRoot()
        return try String(
            contentsOf: root.appendingPathComponent("Tools/HostControlToolSupport/HostControlToolSupport.swift"),
            encoding: .utf8
        )
    }

    private func sourceSnippet(startingWith start: String, endingBefore end: String, in source: String) throws -> String {
        let startIndex = try #require(source.range(of: start)?.lowerBound)
        let endIndex = try #require(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
        return String(source[startIndex..<endIndex])
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw CocoaError(.fileNoSuchFile)
            }
            candidate = parent
        }
    }
}

private final class CapturingHostControlProcessRunner: HostControlProcessRunning {
    struct Request: Equatable {
        var executablePath: String
        var arguments: [String]
        var timeoutSeconds: TimeInterval
        var environment: [String: String]
    }

    private(set) var requests: [Request] = []
    private let result: HostControlCommandResult

    init(result: HostControlCommandResult = HostControlCommandResult(
        command: "/usr/bin/gh",
        arguments: [],
        exitCode: 0,
        stdout: "ok",
        stderr: ""
    )) {
        self.result = result
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        environment: [String: String]
    ) -> HostControlCommandResult {
        requests.append(Request(
            executablePath: executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            environment: environment
        ))
        return result
    }
}
