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

        let bqHelpResult = try call(server, id: 7, tool: "bq", arguments: [
            "arguments": ["--help"]
        ])
        #expect(try resultText(bqHelpResult).contains("bq:--help"))

        let bqShortHelpResult = try call(server, id: 8, tool: "bq", arguments: [
            "arguments": ["-h"]
        ])
        #expect(try resultText(bqShortHelpResult).contains("bq:-h"))

        let bqVersionResult = try call(server, id: 9, tool: "bq", arguments: [
            "arguments": ["version"]
        ])
        #expect(try resultText(bqVersionResult).contains("bq:version"))

        let bqLongVersionResult = try call(server, id: 10, tool: "bq", arguments: [
            "arguments": ["--version"]
        ])
        #expect(try resultText(bqLongVersionResult).contains("bq:--version"))

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

        let jiraSchema = try #require(tools.first { $0["name"] as? String == "jira" })
        let inputSchema = try #require(jiraSchema["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        #expect(properties.keys.contains("issue_key"))
        #expect(properties.keys.contains("jql"))
        #expect(properties.keys.contains("next_page_token"))
        #expect(!properties.keys.contains("method"))
        #expect(!properties.keys.contains("path"))
        #expect(!properties.keys.contains("body"))

        let hostLog = try String(contentsOf: log, encoding: .utf8)
        #expect(hostLog.contains("gh pr view 123 --comments"))
        #expect(hostLog.contains("gcloud compute instances list --format=json"))
        #expect(hostLog.contains("bq --help"))
        #expect(hostLog.contains("bq -h"))
        #expect(hostLog.contains("bq version"))
        #expect(hostLog.contains("bq --version"))
        #expect(hostLog.contains("ssh deid-jsn-workbench hostname && uptime"))

        let diagnosticLog = diagnostics.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false)
        let diagnosticsText = try String(contentsOf: diagnosticLog, encoding: .utf8)
        #expect(diagnosticsText.contains(#""toolName":"github""#))
        #expect(diagnosticsText.contains(#""toolName":"jira""#))
        #expect(!diagnosticsText.contains("super-secret-token"))
    }

    @Test("Host control bq blocks resource access and mutation commands before running host executable")
    func hostControlBQBlocksResourceAccessAndMutationCommandsBeforeRunningHostExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-control-bq-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let bq = try fakeExecutable(named: "bq", root: root, log: log, stdout: "bq:$*")
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(bigQueryExecutable: bq.path))

        let blockedArguments = [
            ["ls", "project:dataset"],
            ["--format=json", "ls", "--project_id", "project"],
            ["show", "project:dataset.table"],
            ["--format=prettyjson", "show", "--schema", "project:dataset.table"],
            ["query", "SELECT * FROM project.dataset.table"],
            ["--help", "query", "SELECT * FROM project.dataset.table"],
            ["--apilog", "help", "query", "SELECT * FROM project.dataset.table"],
            ["--apilog=/tmp/bq.log", "help"],
            ["help", "--apilog=/tmp/bq.log"],
            ["help", "query", "--apilog=/tmp/bq.log"],
            ["query", "DELETE FROM project.dataset.table WHERE true"],
            ["rm", "-f", "project:dataset.table"],
            ["extract", "project:dataset.table", "gs://example/export.json"]
        ]

        for (offset, arguments) in blockedArguments.enumerated() {
            let response = try call(server, id: offset + 1, tool: "bq", arguments: ["arguments": arguments])
            #expect(try errorMessage(response).contains("bq command is not allowed"))
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test("Host control gcloud blocks BigQuery command families before running host executable")
    func hostControlGcloudBlocksBigQueryCommandFamiliesBeforeRunningHostExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-control-gcloud-bigquery-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let gcloud = try fakeExecutable(named: "gcloud", root: root, log: log, stdout: "gcloud:$*")
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(gcloudExecutable: gcloud.path))

        let blockedArguments = [
            ["bq", "tables", "show-rows", "project.dataset.table"],
            ["--project", "project", "bq", "tables", "show-rows", "project.dataset.table"],
            ["--filter", "name~example", "bq", "tables", "show-rows", "project.dataset.table"],
            ["--limit", "10", "bq", "jobs", "list"],
            ["--sort-by", "~creationTimestamp", "bq", "jobs", "list"],
            ["--verbosity", "debug", "bq", "tables", "show-rows", "project.dataset.table"],
            ["alpha", "bq", "tables", "show-rows", "project.dataset.table"],
            ["--access-token-file", "/tmp/token.json", "alpha", "bq", "tables", "show-rows", "project.dataset.table"],
            ["--format=json", "alpha", "bq", "tables", "show-rows", "project.dataset.table"],
            ["--page-size", "50", "beta", "bq", "jobs", "list", "--project=project"],
            ["beta", "bq", "jobs", "list", "--project=project"]
        ]

        for (offset, arguments) in blockedArguments.enumerated() {
            let response = try call(server, id: offset + 1, tool: "gcloud", arguments: ["arguments": arguments])
            #expect(try errorMessage(response).contains("gcloud command is not allowed"))
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test("Host control gcloud allows non-BigQuery commands with bq positional arguments")
    func hostControlGcloudAllowsNonBigQueryCommandsWithBQPositionalArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-control-gcloud-bq-positional-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let gcloud = try fakeExecutable(named: "gcloud", root: root, log: log, stdout: "gcloud:$*")
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(gcloudExecutable: gcloud.path))

        let result = try call(server, id: 1, tool: "gcloud", arguments: [
            "arguments": ["compute", "ssh", "bq"]
        ])

        #expect(try resultText(result).contains("gcloud:compute ssh bq"))
        let hostLog = try String(contentsOf: log, encoding: .utf8)
        #expect(hostLog.contains("gcloud compute ssh bq"))
    }

    @Test("Jira host control rejects raw REST request passthrough")
    func jiraHostControlRejectsRawRESTRequestPassthrough() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"http://127.0.0.1:9","authMethod":"basic","env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_EMAIL_ENV": "user@example.com",
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        )
        let server = HostControlMCPServer(configuration: configuration)

        let response = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "request",
            "method": "DELETE",
            "path": "/rest/api/3/issue/ASTRA-1",
            "body": #"{"deleteSubtasks":true}"#
        ])

        let error = try errorMessage(response)
        #expect(error.contains("Unsupported Jira operation 'request'"))
    }

    @Test("Jira host control search uses vetted read fields")
    func jiraHostControlSearchUsesVettedReadFields() throws {
        JiraCaptureURLProtocol.reset()
        _ = URLProtocol.registerClass(JiraCaptureURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(JiraCaptureURLProtocol.self)
            JiraCaptureURLProtocol.reset()
        }

        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://jira.example.test","authMethod":"basic","env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_EMAIL_ENV": "user@example.com",
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        )
        let server = HostControlMCPServer(configuration: configuration)

        let response = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "search_jql",
            "jql": "project = ASTRA",
            "max_results": 5,
            "next_page_token": "token-123"
        ])

        #expect(try resultText(response).contains("status_code: 200"))
        let url = try #require(JiraCaptureURLProtocol.capturedURLs.last)
        #expect(url.path == "/rest/api/3/search/jql")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fields = try #require(components.queryItems?.first { $0.name == "fields" }?.value)
        #expect(components.queryItems?.first { $0.name == "nextPageToken" }?.value == "token-123")
        #expect(fields.contains("summary"))
        #expect(fields.contains("status"))
        #expect(fields.contains("assignee"))
        #expect(!fields.split(separator: ",").contains("key"))
        #expect(!fields.contains("comment"))
        #expect(!fields.contains("attachment"))
    }

    @Test("Jira host control rejects non HTTP base URL schemes")
    func jiraHostControlRejectsNonHTTPBaseURLSchemes() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"httpx://jira.example.test","authMethod":"basic","env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_EMAIL_ENV": "user@example.com",
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        )
        let server = HostControlMCPServer(configuration: configuration)

        let response = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "status"
        ])

        let text = try resultText(response)
        #expect(text.contains("base_url: <missing or invalid>"))
        #expect(text.contains("ready: false"))
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

    private func errorMessage(_ object: [String: Any]) throws -> String {
        let error = try #require(object["error"] as? [String: Any])
        return try #require(error["message"] as? String)
    }
}

private final class JiraCaptureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URL] = []

    static var capturedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func reset() {
        lock.lock()
        captured = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "jira.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.captured.append(url)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"issues":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
