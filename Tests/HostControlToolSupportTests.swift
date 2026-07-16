import Foundation
import Testing
import ASTRACore
@testable import HostControlToolSupport
@testable import WorkspaceToolSupport

@Suite("Host Control Tool Support", .serialized)
struct HostControlToolSupportTests {
    @Test("GitHub host-control denies credential export and broad mutations before launch")
    func githubHostControlDeniesCredentialExportAndBroadMutationsBeforeLaunch() throws {
        let runner = RecordingHostControlProcessRunner(stdout: "ok")
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "gh"),
            processRunner: runner
        )

        let deniedAuth = try call(server, id: 1, tool: "github", arguments: [
            "arguments": ["auth", "token"]
        ])
        #expect(try errorMessage(deniedAuth).contains("does not allow GitHub operation"))

        let deniedAuthTokenDisplay = try call(server, id: 10, tool: "github", arguments: [
            "arguments": ["auth", "status", "--show-token"]
        ])
        #expect(try errorMessage(deniedAuthTokenDisplay).contains("does not allow GitHub operation"))

        let deniedAuthTokenDisplayShortFlag = try call(server, id: 12, tool: "github", arguments: [
            "arguments": ["auth", "status", "-t"]
        ])
        #expect(try errorMessage(deniedAuthTokenDisplayShortFlag).contains("does not allow GitHub operation"))

        let deniedBundledAuthTokenDisplayShortFlag = try call(server, id: 13, tool: "github", arguments: [
            "arguments": ["auth", "status", "-at"]
        ])
        #expect(try errorMessage(deniedBundledAuthTokenDisplayShortFlag).contains("does not allow GitHub operation"))

        let deniedJQEnvironmentRead = try call(server, id: 14, tool: "github", arguments: [
            "arguments": ["auth", "status", "--json", "hosts", "--jq", "env"]
        ])
        #expect(try errorMessage(deniedJQEnvironmentRead).contains("does not allow GitHub operation"))

        let deniedWebLaunch = try call(server, id: 15, tool: "github", arguments: [
            "arguments": ["pr", "view", "123", "--web"]
        ])
        #expect(try errorMessage(deniedWebLaunch).contains("does not allow GitHub operation"))

        let deniedWebLaunchShortFlag = try call(server, id: 16, tool: "github", arguments: [
            "arguments": ["repo", "view", "owner/project", "-w"]
        ])
        #expect(try errorMessage(deniedWebLaunchShortFlag).contains("does not allow GitHub operation"))

        let deniedBundledWebLaunchShortFlag = try call(server, id: 17, tool: "github", arguments: [
            "arguments": ["pr", "view", "123", "-cw"]
        ])
        #expect(try errorMessage(deniedBundledWebLaunchShortFlag).contains("does not allow GitHub operation"))

        let deniedAttachedJQEnvironmentRead = try call(server, id: 18, tool: "github", arguments: [
            "arguments": ["pr", "view", "123", "--json", "number", "-qenv"]
        ])
        #expect(try errorMessage(deniedAttachedJQEnvironmentRead).contains("does not allow GitHub operation"))

        let deniedMixedArgumentTypes = try call(server, id: 19, tool: "github", arguments: [
            "arguments": ["pr", "view", 123]
        ])
        #expect(try errorMessage(deniedMixedArgumentTypes).contains("arguments array"))

        let deniedAPI = try call(server, id: 2, tool: "github", arguments: [
            "arguments": ["api", "--method", "DELETE", "/repos/example/project"]
        ])
        #expect(try errorMessage(deniedAPI).contains("does not allow GitHub operation"))

        let deniedWorkflow = try call(server, id: 3, tool: "github", arguments: [
            "arguments": ["workflow", "run", "ci.yml"]
        ])
        #expect(try errorMessage(deniedWorkflow).contains("does not allow GitHub operation"))

        let deniedIssueWrite = try call(server, id: 4, tool: "github", arguments: [
            "arguments": ["issue", "create", "--title", "bug"]
        ])
        #expect(try errorMessage(deniedIssueWrite).contains("does not allow GitHub operation"))

        let deniedPRComment = try call(server, id: 5, tool: "github", arguments: [
            "arguments": ["pr", "comment", "123", "--body", "ready"]
        ])
        #expect(try errorMessage(deniedPRComment).contains("does not allow GitHub operation"))

        #expect(runner.invocations.isEmpty)

        let allowed = try call(server, id: 6, tool: "github", arguments: [
            "arguments": ["pr", "view", "123", "--comments"]
        ])
        #expect(try resultText(allowed).contains("ok"))

        let allowedRepoBeforeCommand = try call(server, id: 7, tool: "github", arguments: [
            "arguments": ["--repo", "owner/project", "pr", "view", "123"]
        ])
        #expect(try resultText(allowedRepoBeforeCommand).contains("ok"))

        let allowedRepoBetweenCommandAndSubcommand = try call(server, id: 8, tool: "github", arguments: [
            "arguments": ["pr", "--repo", "owner/project", "view", "123"]
        ])
        #expect(try resultText(allowedRepoBetweenCommandAndSubcommand).contains("ok"))

        let allowedHostnameBetweenCommandAndSubcommand = try call(server, id: 9, tool: "github", arguments: [
            "arguments": ["pr", "--hostname", "github.com", "view", "123"]
        ])
        #expect(try resultText(allowedHostnameBetweenCommandAndSubcommand).contains("ok"))

        let allowedAuthStatus = try call(server, id: 11, tool: "github", arguments: [
            "arguments": ["auth", "status", "--hostname", "github.com"]
        ])
        #expect(try resultText(allowedAuthStatus).contains("ok"))

        let allowedIssueTemplate = try call(server, id: 13, tool: "github", arguments: [
            "arguments": ["issue", "list", "--json", "number,title", "-t", "{{range .}}{{.number}}{{end}}"]
        ])
        #expect(try resultText(allowedIssueTemplate).contains("ok"))

        #expect(runner.invocations.map(\.arguments) == [
            ["pr", "view", "123", "--comments"],
            ["--repo", "owner/project", "pr", "view", "123"],
            ["pr", "--repo", "owner/project", "view", "123"],
            ["pr", "--hostname", "github.com", "view", "123"],
            ["auth", "status", "--hostname", "github.com"],
            ["issue", "list", "--json", "number,title", "-t", "{{range .}}{{.number}}{{end}}"]
        ])
    }

    @Test("Host control MCP enforces allowed tools and forwards workspace current directory")
    func hostControlMCPEnforcesAllowedToolsAndForwardsWorkspaceCurrentDirectory() throws {
        let runner = RecordingHostControlProcessRunner(stdout: "ok")
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: "gh",
                gcloudExecutable: "gcloud",
                allowedTools: ["github"],
                currentDirectory: "/tmp/astra-workspace"
            ),
            processRunner: runner
        )

        let list = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["github"])

        let denied = try call(server, id: 2, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list"]
        ])
        #expect(try errorMessage(denied).contains("not enabled for this task"))
        #expect(runner.invocations.isEmpty)

        let allowed = try call(server, id: 3, tool: "github", arguments: [
            "arguments": ["pr", "view", "123"]
        ])
        #expect(try resultText(allowed).contains("ok"))
        #expect(runner.invocations.last?.currentDirectory == "/tmp/astra-workspace")

        let normalizedAllowed = try call(server, id: 4, tool: " GitHub ", arguments: [
            "arguments": ["pr", "view", "456"]
        ])
        #expect(try resultText(normalizedAllowed).contains("ok"))
        #expect(runner.invocations.last?.arguments == ["pr", "view", "456"])

        #expect(HostControlToolConfiguration.fromEnvironment([:]).allowedTools == HostControlToolConfiguration.knownToolNames)
        #expect(HostControlToolConfiguration.fromEnvironment(["ASTRA_HOST_CONTROL_ALLOWED_TOOLS": ""]).allowedTools.isEmpty)
    }

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
        let sshSchema = try #require(tools.first { $0["name"] as? String == "ssh" })
        let sshDescription = try #require(sshSchema["description"] as? String)
        #expect(sshDescription.contains("non-interactive"))
        #expect(sshDescription.contains("remote commands are not supported"))

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
            "alias": "deid-jsn-workbench"
        ])
        #expect(try resultText(sshResult).contains("ssh:-o BatchMode=yes -o RequestTTY=no -o StdinNull=yes -o ClearAllForwardings=yes -- deid-jsn-workbench true"))

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
        #expect(hostLog.contains("ssh -o BatchMode=yes -o RequestTTY=no -o StdinNull=yes -o ClearAllForwardings=yes -- deid-jsn-workbench true"))
        #expect(!hostLog.contains("hostname && uptime"))

        let diagnosticLog = diagnostics.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false)
        let diagnosticsText = try String(contentsOf: diagnosticLog, encoding: .utf8)
        #expect(diagnosticsText.contains(#""toolName":"github""#))
        #expect(diagnosticsText.contains(#""toolName":"jira""#))
        #expect(!diagnosticsText.contains("super-secret-token"))
    }

    @Test("Host control SSH rejects command-shaped inputs before invoking ssh")
    func hostControlSSHRejectsCommandShapedInputsBeforeInvokingSSH() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-control-ssh-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let ssh = try fakeExecutable(named: "ssh", root: root, log: log, stdout: "ssh:$*")
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(
            sshExecutable: ssh.path,
            allowedSSHAliases: ["deid-jsn-workbench"]
        ))

        let commandInputs: [[String: Any]] = [
            ["alias": "deid-jsn-workbench", "remote_command": "hostname && uptime"],
            ["alias": "deid-jsn-workbench", "command": "hostname && uptime"],
            ["alias": "deid-jsn-workbench", "cmd": "hostname && uptime"],
            ["alias": "deid-jsn-workbench", "arguments": ["hostname"]]
        ]

        for (index, arguments) in commandInputs.enumerated() {
            let response = try call(server, id: index + 1, tool: "ssh", arguments: arguments)
            let error = try #require(response["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32602)
            #expect((error["message"] as? String)?.contains("remote commands are not supported") == true)
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test("Host control SSH uses a non-interactive reachability probe")
    func hostControlSSHUsesNonInteractiveReachabilityProbe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-control-ssh-noninteractive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let ssh = try fakeExecutable(named: "ssh", root: root, log: log, stdout: "ssh:$*")
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(
            sshExecutable: ssh.path,
            allowedSSHAliases: ["deid-jsn-workbench"]
        ))

        let response = try call(server, id: 1, tool: "ssh", arguments: [
            "alias": "deid-jsn-workbench"
        ])

        #expect(try resultText(response).contains("ssh:-o BatchMode=yes -o RequestTTY=no -o StdinNull=yes -o ClearAllForwardings=yes -- deid-jsn-workbench true"))
        let logText = try String(contentsOf: log, encoding: .utf8)
        #expect(logText.contains("ssh -o BatchMode=yes -o RequestTTY=no -o StdinNull=yes -o ClearAllForwardings=yes -- deid-jsn-workbench true"))
        #expect(!logText.contains("ssh deid-jsn-workbench\n"))
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
            "arguments": ["compute", "instances", "describe", "bq"]
        ])

        #expect(try resultText(result).contains("gcloud:compute instances describe bq"))
        let hostLog = try String(contentsOf: log, encoding: .utf8)
        #expect(hostLog.contains("gcloud compute instances describe bq"))
    }

    @Test("Host control gcloud denies credential printing and mutations before process execution")
    func hostControlGCloudDeniesCredentialPrintingAndMutationsBeforeProcessExecution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-gcloud-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let gcloud = try fakeExecutable(named: "gcloud", root: root, log: log, stdout: "gcloud:$*")
        let configuration = HostControlToolConfiguration(gcloudExecutable: gcloud.path)
        let server = HostControlMCPServer(configuration: configuration)

        let tokenResult = try call(server, id: 1, tool: "gcloud", arguments: [
            "arguments": ["auth", "print-access-token"]
        ])
        let tokenError = try #require(tokenResult["error"] as? [String: Any])
        #expect((tokenError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let mutationResult = try call(server, id: 2, tool: "gcloud", arguments: [
            "arguments": ["run", "deploy", "prod-service", "--image", "gcr.io/example/app"]
        ])
        let mutationError = try #require(mutationResult["error"] as? [String: Any])
        #expect((mutationError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let disguisedMutationResult = try call(server, id: 3, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "reset", "list", "--zone=us-central1-a"]
        ])
        let disguisedMutationError = try #require(disguisedMutationResult["error"] as? [String: Any])
        #expect((disguisedMutationError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let readResult = try call(server, id: 4, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list", "--format=json"]
        ])
        #expect(try resultText(readResult).contains("gcloud:compute instances list --format=json"))

        let filteredReadResult = try call(server, id: 5, tool: "gcloud", arguments: [
            "arguments": [
                "--project", "clinical-project",
                "--filter", "name~worker",
                "compute", "instances", "list",
                "--format=json"
            ]
        ])
        #expect(try resultText(filteredReadResult).contains("gcloud:--project clinical-project --filter name~worker compute instances list --format=json"))

        let workflowRunResult = try call(server, id: 6, tool: "gcloud", arguments: [
            "arguments": ["workflows", "run", "list", "--location=us-central1"]
        ])
        let workflowRunError = try #require(workflowRunResult["error"] as? [String: Any])
        #expect((workflowRunError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let schedulerRunResult = try call(server, id: 17, tool: "gcloud", arguments: [
            "arguments": ["scheduler", "jobs", "run", "list", "--location", "us-central1"]
        ])
        let schedulerRunError = try #require(schedulerRunResult["error"] as? [String: Any])
        #expect((schedulerRunError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let flagsFileResult = try call(server, id: 7, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list", "--flags-file=/tmp/hidden-credentials.yaml"]
        ])
        let flagsFileError = try #require(flagsFileResult["error"] as? [String: Any])
        #expect((flagsFileError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let passthroughSeparatorResult = try call(server, id: 18, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list", "--", "--access-token-file=/tmp/hidden-token"]
        ])
        let passthroughSeparatorError = try #require(passthroughSeparatorResult["error"] as? [String: Any])
        #expect((passthroughSeparatorError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let iamPolicyReadResult = try call(server, id: 8, tool: "gcloud", arguments: [
            "arguments": ["projects", "get-iam-policy", "clinical-project"]
        ])
        let iamPolicyReadError = try #require(iamPolicyReadResult["error"] as? [String: Any])
        #expect((iamPolicyReadError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let httpLoggingReadResult = try call(server, id: 9, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list", "--log-http"]
        ])
        let httpLoggingReadError = try #require(httpLoggingReadResult["error"] as? [String: Any])
        #expect((httpLoggingReadError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let uriHTTPLoggingReadResult = try call(server, id: 19, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list", "--uri", "--log-http"]
        ])
        let uriHTTPLoggingReadError = try #require(uriHTTPLoggingReadResult["error"] as? [String: Any])
        #expect((uriHTTPLoggingReadError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let debugVerbosityReadResult = try call(server, id: 10, tool: "gcloud", arguments: [
            "arguments": ["--verbosity", "debug", "compute", "instances", "list"]
        ])
        let debugVerbosityReadError = try #require(debugVerbosityReadResult["error"] as? [String: Any])
        #expect((debugVerbosityReadError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let inlineDebugVerbosityReadResult = try call(server, id: 11, tool: "gcloud", arguments: [
            "arguments": ["compute", "instances", "list", "--verbosity=debug"]
        ])
        let inlineDebugVerbosityReadError = try #require(inlineDebugVerbosityReadResult["error"] as? [String: Any])
        #expect((inlineDebugVerbosityReadError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let traceTokenReadResult = try call(server, id: 12, tool: "gcloud", arguments: [
            "arguments": [
                "--trace-token", "task-token-for-log-correlation",
                "--filter", "labels.audit=tokenized-read",
                "compute", "instances", "list"
            ]
        ])
        #expect(try resultText(traceTokenReadResult).contains("gcloud:--trace-token task-token-for-log-correlation --filter labels.audit=tokenized-read compute instances list"))

        let sensitiveWordFilterReadResult = try call(server, id: 13, tool: "gcloud", arguments: [
            "arguments": [
                "compute", "instances", "list",
                "--filter", "labels.purpose=secret-rotation-check",
                "--format=json"
            ]
        ])
        #expect(try resultText(sensitiveWordFilterReadResult).contains("gcloud:compute instances list --filter labels.purpose=secret-rotation-check --format=json"))

        let sensitiveWordResourceReadResult = try call(server, id: 14, tool: "gcloud", arguments: [
            "arguments": [
                "compute", "instances", "describe", "secret-rotation-checker",
                "--zone=us-central1-a"
            ]
        ])
        #expect(try resultText(sensitiveWordResourceReadResult).contains("gcloud:compute instances describe secret-rotation-checker --zone=us-central1-a"))

        let locationReadResult = try call(server, id: 15, tool: "gcloud", arguments: [
            "arguments": [
                "--location", "us-central1",
                "functions", "list"
            ]
        ])
        #expect(try resultText(locationReadResult).contains("gcloud:--location us-central1 functions list"))

        let impersonationReadResult = try call(server, id: 16, tool: "gcloud", arguments: [
            "arguments": [
                "compute", "instances", "list",
                "--impersonate-service-account=reader@example.iam.gserviceaccount.com"
            ]
        ])
        let impersonationReadError = try #require(impersonationReadResult["error"] as? [String: Any])
        #expect((impersonationReadError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let hostLog = try String(contentsOf: log, encoding: .utf8)
        #expect(!hostLog.contains("auth print-access-token"))
        #expect(!hostLog.contains("run deploy"))
        #expect(!hostLog.contains("compute instances reset list"))
        #expect(!hostLog.contains("workflows run list"))
        #expect(!hostLog.contains("scheduler jobs run list"))
        #expect(!hostLog.contains("--flags-file"))
        #expect(!hostLog.contains("--access-token-file"))
        #expect(!hostLog.contains("get-iam-policy"))
        #expect(!hostLog.contains("--log-http"))
        #expect(!hostLog.contains("--uri --log-http"))
        #expect(!hostLog.contains("--verbosity debug"))
        #expect(!hostLog.contains("--verbosity=debug"))
        #expect(!hostLog.contains("--impersonate-service-account"))
        #expect(hostLog.contains("gcloud compute instances list --format=json"))
        #expect(hostLog.contains("gcloud --project clinical-project --filter name~worker compute instances list --format=json"))
        #expect(hostLog.contains("gcloud --trace-token task-token-for-log-correlation --filter labels.audit=tokenized-read compute instances list"))
        #expect(hostLog.contains("gcloud compute instances list --filter labels.purpose=secret-rotation-check --format=json"))
        #expect(hostLog.contains("gcloud compute instances describe secret-rotation-checker --zone=us-central1-a"))
        #expect(hostLog.contains("gcloud --location us-central1 functions list"))
    }

    @Test("Host control gcloud denies credential selecting flags before process execution")
    func hostControlGCloudDeniesCredentialSelectingFlagsBeforeProcessExecution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-gcloud-credential-flags-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let gcloud = try fakeExecutable(named: "gcloud", root: root, log: log, stdout: "gcloud:$*")
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(gcloudExecutable: gcloud.path)
        )
        let deniedFlagCases: [[String]] = [
            ["--account", "privileged@example.com", "compute", "instances", "list"],
            ["--account=privileged@example.com", "compute", "instances", "list"],
            ["--configuration", "debug-config", "compute", "instances", "list"],
            ["--configuration=debug-config", "compute", "instances", "list"],
            ["auth", "activate-service-account", "--key-file", "/tmp/private-key.json"],
            ["auth", "activate-service-account", "--key-file=/tmp/private-key.json"]
        ]

        for (offset, arguments) in deniedFlagCases.enumerated() {
            let result = try call(server, id: 20 + offset, tool: "gcloud", arguments: [
                "arguments": arguments
            ])
            let error = try #require(result["error"] as? [String: Any])
            #expect((error["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)
        }

        let hostLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(!hostLog.contains("--account"))
        #expect(!hostLog.contains("--configuration"))
        #expect(!hostLog.contains("/tmp/private-key.json"))
    }

    @Test("Host control records denied gcloud policy attempts")
    func hostControlRecordsDeniedGCloudPolicyAttempts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-gcloud-denied-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let log = root.appendingPathComponent("host.log", isDirectory: false)
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        let gcloud = try fakeExecutable(named: "gcloud", root: root, log: log, stdout: "gcloud:$*")
        let configuration = HostControlToolConfiguration(
            gcloudExecutable: gcloud.path,
            diagnosticsHostPath: diagnostics.path,
            taskID: "task-denied-gcloud",
            runID: "run-denied-gcloud"
        )
        let server = HostControlMCPServer(
            configuration: configuration,
            diagnosticsRecorder: HostControlToolDiagnosticsRecorder(configuration: configuration)
        )

        let result = try call(server, id: 30, tool: "gcloud", arguments: [
            "arguments": ["auth", "print-access-token"]
        ])
        let error = try #require(result["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let sensitiveFlagResult = try call(server, id: 31, tool: "gcloud", arguments: [
            "arguments": [
                "--account", "privileged@example.com",
                "compute", "instances", "list",
                "--access-token=synthetic-access-token-value",
                "--key-file", "/tmp/private-key.json",
                "--key-file=/tmp/inline-private-key.json",
                "--impersonate-service-account=reader@example.iam.gserviceaccount.com"
            ]
        ])
        let sensitiveFlagError = try #require(sensitiveFlagResult["error"] as? [String: Any])
        #expect((sensitiveFlagError["message"] as? String)?.contains("gcloud does not allow credential or mutating operations") == true)

        let hostLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(!hostLog.contains("auth print-access-token"))
        #expect(!hostLog.contains("privileged@example.com"))
        #expect(!hostLog.contains("synthetic-access-token-value"))
        #expect(!hostLog.contains("/tmp/private-key.json"))
        #expect(!hostLog.contains("/tmp/inline-private-key.json"))
        #expect(!hostLog.contains("reader@example.iam.gserviceaccount.com"))

        let diagnosticLog = diagnostics.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false)
        let diagnosticsText = try String(contentsOf: diagnosticLog, encoding: .utf8)
        #expect(diagnosticsText.contains(#""toolName":"gcloud""#))
        #expect(diagnosticsText.contains(#""taskID":"task-denied-gcloud""#))
        #expect(diagnosticsText.contains(#""runID":"run-denied-gcloud""#))
        #expect(diagnosticsText.contains(#""summary":"gcloud auth print-access-token""#))
        #expect(diagnosticsText.contains(#"--account <redacted>"#))
        #expect(diagnosticsText.contains(#"--access-token=<redacted>"#))
        #expect(diagnosticsText.contains(#"--key-file <redacted>"#))
        #expect(diagnosticsText.contains(#"--key-file=<redacted>"#))
        #expect(diagnosticsText.contains(#"--impersonate-service-account=<redacted>"#))
        #expect(!diagnosticsText.contains("privileged@example.com"))
        #expect(!diagnosticsText.contains("synthetic-access-token-value"))
        #expect(!diagnosticsText.contains("/tmp/private-key.json"))
        #expect(!diagnosticsText.contains("/tmp/inline-private-key.json"))
        #expect(!diagnosticsText.contains("reader@example.iam.gserviceaccount.com"))
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
        HostControlURLSessionConfiguration.protocolClassesForTesting = [JiraCaptureURLProtocol.self]
        defer {
            HostControlURLSessionConfiguration.protocolClassesForTesting = []
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
        _ = try call(hostServer, id: 3, tool: "ssh", arguments: ["alias": "deid-jsn-workbench"])
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

        let workspaceTaskID = "11111111-1111-4111-8111-111111111111"
        let workspaceRunID = "22222222-2222-4222-8222-222222222222"
        let jobRoot = root.appendingPathComponent(".astra/tasks/\(workspaceTaskID)/jobs", isDirectory: true)
        let workspaceConfiguration = WorkspaceToolConfiguration(
            dockerExecutable: docker.path,
            image: "astra/workspace:latest",
            containerName: "astra-mixed",
            workdir: "/workspace",
            network: "bridge",
            taskID: workspaceTaskID,
            runID: workspaceRunID,
            mounts: [
                WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
            ],
            jobRootHostPath: jobRoot.path,
            jobRootContainerPath: "/workspace/.astra/tasks/\(workspaceTaskID)/jobs",
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
        let startResult = try JSONDecoder().decode(
            WorkspaceManagedJobStructuredResult.self,
            from: Data(try resultText(start).utf8)
        )
        #expect(startResult.status == .running)
        #expect(startResult.startReceipt?.taskID.uuidString == workspaceTaskID)
        workspaceServer.cleanup()

        let hostLogText = try String(contentsOf: hostLog, encoding: .utf8)
        #expect(hostLogText.contains("gh pr view 123 --comments"))
        #expect(hostLogText.contains("gcloud compute instances list"))
        #expect(hostLogText.contains("ssh -o BatchMode=yes -o RequestTTY=no -o StdinNull=yes -o ClearAllForwardings=yes -- deid-jsn-workbench true"))
        #expect(!hostLogText.contains("uptime"))

        let dockerLogText = try String(contentsOf: dockerLog, encoding: .utf8)
        #expect(dockerLogText.contains("exec -i --workdir /workspace astra-mixed sh -c command -v sqlfmt && sqlfmt --version"))
        #expect(dockerLogText.contains("exec -d --workdir /workspace astra-mixed sh -c"))
        #expect(!dockerLogText.split(separator: "\n").contains("stop astra-mixed"))
        #expect(!dockerLogText.contains("gh pr"))
        #expect(!dockerLogText.contains("gcloud compute"))
        #expect(!dockerLogText.contains("ssh -o BatchMode=yes"))

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
        let jobStartRecord = try #require(workspaceRecords.first {
            $0["toolName"] as? String == "workspace_job_start"
        })
        #expect(jobStartRecord["command"] == nil)
        #expect(jobStartRecord["mappedCommand"] == nil)
        #expect(!workspaceActivity.contains("dbt build --select +death"))
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

    @Test("Host control process limits clamp huge finite configured timeout caps")
    func hostControlProcessLimitsClampHugeFiniteConfiguredTimeoutCaps() {
        let limits = HostControlProcessLimits(maximumTimeoutSeconds: .greatestFiniteMagnitude, outputByteLimit: 1024)

        #expect(limits.maximumTimeoutSeconds == 86_400)
        #expect(limits.clampedTimeout(.greatestFiniteMagnitude) == 86_400)
    }

    @Test("Host control process limits are immutable after validation")
    func hostControlProcessLimitsAreImmutableAfterValidation() throws {
        let source = try hostControlToolSource()
        let definition = try sourceSnippet(
            startingWith: "public struct HostControlProcessLimits",
            endingBefore: "public protocol HostControlProcessRunning",
            in: source
        )

        #expect(definition.contains("public let maximumTimeoutSeconds"))
        #expect(definition.contains("public let outputByteLimit"))
        #expect(!definition.contains("public var maximumTimeoutSeconds"))
        #expect(!definition.contains("public var outputByteLimit"))
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

    @Test("Host control process runner treats abandoned pipe reads as truncated")
    func hostControlProcessRunnerTreatsAbandonedPipeReadsAsTruncated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-abandoned-pipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The orphaned background subshell must hold the stdout pipe's write end open
        // for the entire test with zero dependence on wall-clock timing. Two independent
        // hazards had to be removed to make that true:
        //
        // 1. A `sleep N` orphan races real time: if the assertions (or a loaded CI box)
        //    take longer than N seconds to reach the read, the orphan wakes up, writes
        //    the "secret", and the pipe closes cleanly before truncation is observed.
        //    Fixed by having the orphan block forever on a `read` from a FIFO this test
        //    never writes to — there is no duration to race, only "still blocked or not".
        //
        // 2. HostControlScopedProcess reaps the foreground `gh` script and then signals
        //    the *whole spawned process group* (SIGTERM, ~200ms grace, SIGKILL) to clean up
        //    stragglers. An orphan backgrounded with a plain `&` inherits that same process
        //    group, so this cleanup kills it — and whether HostControlProcessRunner's own
        //    pipe drain observes the still-open pipe (EAGAIN, the "abandoned" condition this
        //    test targets) or the just-closed pipe (a clean EOF, indistinguishable from a
        //    normal exit) is a genuine race between the drain and the kernel finishing off
        //    the killed orphan. Fixed by running the orphan with `set -m` (job control)
        //    first: POSIX shells place a monitored background job in its *own* new process
        //    group, distinct from the script's. HostControlScopedProcess's group-kill can
        //    then never reach the orphan at all — it isn't a faster race, it's no longer a
        //    race, since nothing in this test process ever signals that group.
        //
        // The orphan is reaped by the OS when this process exits (or the FIFO gate is
        // nudged in the `defer` below); it is never left running as a lingering test-suite
        // side effect beyond that.
        let gate = root.appendingPathComponent("gate.fifo", isDirectory: false)
        guard mkfifo(gate.path, 0o600) == 0 else {
            Issue.record("Failed to create control FIFO for abandoned-pipe test: errno \(errno)")
            return
        }

        let gh = try customExecutable(named: "gh", root: root, body: """
        set -m
        ( read _line < "\(gate.path)"; printf 'et-token' ) &
        printf 'visible-prefix:super-secr'
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
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 256)
        )

        defer {
            // Best-effort: nudge the orphaned `read` awake so it exits and no stray
            // process outlives the test, since (by design, see above) it lives outside
            // the process group HostControlScopedProcess cleans up. This must never
            // block: opening a FIFO for writing blocks until a reader is present, and
            // if the orphan already exited for any other reason there is no reader at
            // all. O_NONBLOCK makes the open return ENXIO immediately in that case
            // instead of hanging the test.
            let fd = open(gate.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
            }
        }

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let text = try resultText(response)

        #expect(text.contains("exit_code: 125"))
        #expect(text.contains("output_truncated: true"))
        #expect(text.contains("stdout_truncated: true"))
        #expect(text.contains("ASTRA truncated stdout after"))
        #expect(!text.contains("super-secr"))
        #expect(!text.contains("super-secret-token"))
        #expect(!text.contains("et-token"))
        #expect(try #require(response["result"] as? [String: Any])["isError"] as? Bool == true)
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

    @Test("Host control process runner caps decoded output after invalid UTF-8 expansion")
    func hostControlProcessRunnerCapsDecodedOutputAfterInvalidUTF8Expansion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-invalid-utf8-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let invalidByteEscapes = String(repeating: "\\200", count: 64)
        let executable = try customExecutable(named: "invalid-utf8", root: root, body: """
        printf '%b' '\(invalidByteEscapes)'
        exit 0
        """)

        let result = HostControlProcessRunner(limits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 64)).run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 5,
            environment: [:]
        )

        #expect(result.exitCode == 125)
        #expect(result.stdoutTruncated)
        #expect(Data(result.stdout.utf8).count <= 64)
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
        #expect(Date().timeIntervalSince(started) < 4)
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
        #expect(source.contains("guard !data.isEmpty else"))
        #expect(drain.contains("guard flags >= 0 else"))
        #expect(drain.contains("guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else"))
        #expect(drain.contains("guard let handle = reader.claimForDrain() else { return }"))
        #expect(drain.contains("buffer.markTruncated()"))
        #expect(drain.contains("defer { try? handle.close() }"))
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
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test("Host control process runner reaps inherited child processes before returning")
    func hostControlProcessRunnerReapsInheritedChildProcessesBeforeReturning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-runner-inherited-pipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let marker = root.appendingPathComponent("child-survived", isDirectory: false)
        let executable = try customExecutable(named: "detached-noisy-child", root: root, body: """
        (sleep 1; touch "\(marker.path)") &
        exit 0
        """)
        let started = Date()

        let result = HostControlProcessRunner(limits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 32)).run(
            executablePath: executable.path,
            arguments: [],
            timeoutSeconds: 5,
            environment: [:]
        )

        Thread.sleep(forTimeInterval: 1.2)
        #expect(result.exitCode == 0 || result.exitCode == 125)
        if result.exitCode == 125 {
            #expect(result.stdoutTruncated || result.stderrTruncated)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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

    @Test("Host control tool schemas never describe huge finite timeout caps")
    func hostControlToolSchemasNeverDescribeHugeFiniteTimeoutCaps() throws {
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: .greatestFiniteMagnitude, outputByteLimit: 1024)
        )

        let list = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])

        for tool in tools {
            let inputSchema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(inputSchema["properties"] as? [String: Any])
            let timeout = try #require(properties["timeout_seconds"] as? [String: Any])
            let description = try #require(timeout["description"] as? String)
            #expect(description.contains("capped at 86400 seconds"))
            #expect(!description.lowercased().contains("inf"))
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

    @Test("Host control redacts short secret prefixes at capped output markers")
    func hostControlRedactsShortSecretPrefixesAtCappedOutputMarkers() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let runner = CapturingHostControlProcessRunner(result: HostControlCommandResult(
            command: "/usr/bin/gh",
            arguments: ["pr", "view", "123"],
            exitCode: 125,
            stdout: "visible-prefix:su\n[ASTRA redacted stdout output capped after 96 bytes]\n",
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

    @Test("Host control redacts short secret prefixes after final caps create markers")
    func hostControlRedactsShortSecretPrefixesAfterFinalCapsCreateMarkers() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let outputLimit = 96
        let marker = "\n[ASTRA redacted stdout output capped after \(outputLimit) bytes]\n"
        let leakedPrefix = "visible-prefix:su"
        let filler = String(repeating: "x", count: max(0, outputLimit - marker.utf8.count - leakedPrefix.utf8.count))
        let runner = CapturingHostControlProcessRunner(result: HostControlCommandResult(
            command: "/usr/bin/gh",
            arguments: ["pr", "view", "123"],
            exitCode: 0,
            stdout: filler + leakedPrefix + String(repeating: "z", count: 200),
            stderr: ""
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
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: outputLimit)
        )

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let stdout = try stdoutSection(in: resultText(response))

        #expect(stdout.utf8.count <= outputLimit)
        #expect(!stdout.contains("visible-prefix:su"))
        #expect(!stdout.contains("super-secret-token"))
        #expect(try #require(response["result"] as? [String: Any])["isError"] as? Bool == true)
    }

    @Test("Host control short secret prefix scan only checks truncation boundaries")
    func hostControlShortSecretPrefixScanOnlyChecksTruncationBoundaries() throws {
        let source = try hostControlToolSource()
        let prefixScan = try sourceSnippet(
            startingWith: "    private func mergedSecretPrefixRanges(",
            endingBefore: "    private static func splitList",
            in: source
        )

        let boundaryScanCount = prefixScan.components(separatedBy: "truncatedOutputBoundaries(in: value)").count - 1
        #expect(boundaryScanCount == 1)
        #expect(prefixScan.contains("boundaries: boundaries"))
        #expect(prefixScan.contains("output capped after"))
        #expect(!prefixScan.contains("for index in value.indices"))
        #expect(!prefixScan.contains("Array(value[range])"))
        #expect(!prefixScan.contains("secret.prefix(length)"))
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

    @Test("Host control caps redacted output even when runner did not truncate")
    func hostControlCapsRedactedOutputEvenWhenRunnerDidNotTruncate() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let runner = CapturingHostControlProcessRunner(result: HostControlCommandResult(
            command: "/usr/bin/gh",
            arguments: ["pr", "view", "123"],
            exitCode: 0,
            stdout: String(repeating: "pass", count: 40),
            stderr: "",
            stdoutTruncated: false
        ))
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                githubExecutable: "/usr/bin/gh",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_TOKEN_ENV": "pass"
                ]
            ),
            processRunner: runner,
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 5, outputByteLimit: 96)
        )

        let response = try call(server, id: 1, tool: "github", arguments: ["arguments": ["pr", "view", "123"]])
        let stdout = try stdoutSection(in: resultText(response))

        #expect(stdout.utf8.count <= 96)
        #expect(stdout.contains("redacted"))
        #expect(!stdout.contains("pass"))
        #expect(try #require(response["result"] as? [String: Any])["isError"] as? Bool == true)
        #expect(try resultText(response).contains("output_truncated: true"))
    }

    @Test("Jira truncated response bodies redact secret prefixes and become errors")
    func jiraTruncatedResponseBodiesRedactSecretPrefixesAndBecomeErrors() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        )
        let response = JiraHTTPResponse(
            statusCode: 200,
            body: "visible-prefix:super-secr\n[ASTRA truncated Jira response body after 25 bytes]\n",
            errorMessage: nil,
            bodyTruncated: true
        )

        let formatted = response.formatted(configuration: configuration, outputByteLimit: 256)

        #expect(response.isError)
        #expect(formatted.contains("body_truncated: true"))
        #expect(formatted.contains("visible-prefix:[redacted]"))
        #expect(!formatted.contains("super-secr"))
        #expect(!formatted.contains("super-secret-token"))
    }

    @Test("Jira response formatter reapplies caps after redaction")
    func jiraResponseFormatterReappliesCapsAfterRedaction() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        )
        let response = JiraHTTPResponse(
            statusCode: 200,
            body: String(repeating: "supe", count: 40),
            errorMessage: nil,
            bodyTruncated: true
        )

        let body = try bodySection(in: response.formatted(configuration: configuration, outputByteLimit: 96))

        #expect(body.utf8.count <= 96)
        #expect(body.contains("redacted"))
        #expect(!body.contains("supe"))
    }

    @Test("Jira formatted caps mark otherwise successful responses as errors")
    func jiraFormattedCapsMarkOtherwiseSuccessfulResponsesAsErrors() throws {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira","serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic","env":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"credentials":{"JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_TOKEN_ENV": "supe"
            ]
        )
        let response = JiraHTTPResponse(
            statusCode: 200,
            body: String(repeating: "supe", count: 12),
            errorMessage: nil,
            bodyTruncated: false
        )

        let formatted = response.formattedPayload(configuration: configuration, outputByteLimit: 64)

        #expect(!response.isError)
        #expect(formatted.bodyTruncated)
        #expect(formatted.text.contains("body_truncated: true"))
        #expect(!formatted.text.contains("supe"))
    }

    private func fakeExecutable(named name: String, root: URL, log: URL, stdout: String) throws -> URL {
        let executable = root.appendingPathComponent(name, isDirectory: false)
        let quotedLog = shellSingleQuoted(log.path)
        let stdoutCommands = fakeExecutableStdoutCommands(for: stdout)
        try """
        #!/bin/sh
        printf '\(name) %s\\n' "$*" >> \(quotedLog)
        \(stdoutCommands)
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func fakeExecutableStdoutCommands(for stdout: String) -> String {
        stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let rendered = fakeExecutablePrintf(for: String(line))
                return "printf \(rendered.format) \(rendered.arguments.joined(separator: " "))"
            }
            .joined(separator: "\n")
    }

    private func fakeExecutablePrintf(for line: String) -> (format: String, arguments: [String]) {
        var remaining = line[...]
        var format = ""
        var arguments: [String] = []

        while !remaining.isEmpty {
            let nextArg = remaining.range(of: "$*")
            let nextSecret = remaining.range(of: "$JIRA_TOKEN_ENV")
            let next = [nextArg, nextSecret]
                .compactMap { $0 }
                .min { $0.lowerBound < $1.lowerBound }

            guard let range = next else {
                format += fakeExecutablePrintfLiteral(String(remaining))
                remaining = remaining[remaining.endIndex...]
                continue
            }

            format += fakeExecutablePrintfLiteral(String(remaining[..<range.lowerBound]))
            format += "%s"
            arguments.append(range == nextArg ? "\"$*\"" : "\"$JIRA_TOKEN_ENV\"")
            remaining = remaining[range.upperBound...]
        }

        return (shellSingleQuoted(format + "\\n"), arguments)
    }

    private func fakeExecutablePrintfLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "%%")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

    private func errorMessage(_ object: [String: Any]) throws -> String {
        let error = try #require(object["error"] as? [String: Any])
        return try #require(error["message"] as? String)
    }

    private func stdoutSection(in text: String) throws -> String {
        let start = try #require(text.range(of: "stdout:\n"))
        let end = try #require(text.range(of: "\nstderr:", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    private func bodySection(in text: String) throws -> String {
        let start = try #require(text.range(of: "body:\n"))
        let end = try #require(text.range(of: "\nerror:", range: start.upperBound..<text.endIndex))
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
        try TestRepositoryRoot.resolve()
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

private final class CapturingHostControlProcessRunner: HostControlProcessRunning {
    struct Request: Equatable {
        var executablePath: String
        var arguments: [String]
        var timeoutSeconds: TimeInterval
        var environment: [String: String]
        var currentDirectory: String?
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
        environment: [String: String],
        currentDirectory: String?
    ) -> HostControlCommandResult {
        requests.append(Request(
            executablePath: executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            environment: environment,
            currentDirectory: currentDirectory
        ))
        return result
    }
}

private final class RecordingHostControlProcessRunner: HostControlProcessRunning {
    struct Invocation: Equatable {
        var executablePath: String
        var arguments: [String]
        var timeoutSeconds: TimeInterval
        var environment: [String: String]
        var currentDirectory: String?
    }

    private(set) var invocations: [Invocation] = []
    private let stdout: String

    init(stdout: String) {
        self.stdout = stdout
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        environment: [String: String],
        currentDirectory: String?
    ) -> HostControlCommandResult {
        invocations.append(Invocation(
            executablePath: executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            environment: environment,
            currentDirectory: currentDirectory
        ))
        return HostControlCommandResult(
            command: executablePath,
            arguments: arguments,
            exitCode: 0,
            stdout: stdout,
            stderr: ""
        )
    }
}
