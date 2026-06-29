import Foundation

public struct HostControlToolConfiguration: Equatable, Sendable {
    public var githubExecutable: String
    public var gcloudExecutable: String
    public var bigQueryExecutable: String
    public var sshExecutable: String
    public var allowedSSHAliases: [String]
    public var diagnosticsHostPath: String
    public var taskID: String
    public var runID: String
    public var connectorsJSON: String
    public var environment: [String: String]

    public init(
        githubExecutable: String = "gh",
        gcloudExecutable: String = "gcloud",
        bigQueryExecutable: String = "bq",
        sshExecutable: String = "ssh",
        allowedSSHAliases: [String] = [],
        diagnosticsHostPath: String = "",
        taskID: String = "unknown-task",
        runID: String = "unknown-run",
        connectorsJSON: String = #"{"connectors":[]}"#,
        environment: [String: String] = [:]
    ) {
        self.githubExecutable = Self.clean(githubExecutable) ?? "gh"
        self.gcloudExecutable = Self.clean(gcloudExecutable) ?? "gcloud"
        self.bigQueryExecutable = Self.clean(bigQueryExecutable) ?? "bq"
        self.sshExecutable = Self.clean(sshExecutable) ?? "ssh"
        self.allowedSSHAliases = Self.deduplicated(allowedSSHAliases.compactMap(Self.clean))
        self.diagnosticsHostPath = Self.clean(diagnosticsHostPath) ?? ""
        self.taskID = Self.clean(taskID) ?? "unknown-task"
        self.runID = Self.clean(runID) ?? "unknown-run"
        self.connectorsJSON = Self.clean(connectorsJSON) ?? #"{"connectors":[]}"#
        self.environment = environment
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HostControlToolConfiguration {
        HostControlToolConfiguration(
            githubExecutable: clean(env["ASTRA_HOST_CONTROL_GH_EXECUTABLE"]) ?? "gh",
            gcloudExecutable: clean(env["ASTRA_HOST_CONTROL_GCLOUD_EXECUTABLE"]) ?? "gcloud",
            bigQueryExecutable: clean(env["ASTRA_HOST_CONTROL_BQ_EXECUTABLE"]) ?? "bq",
            sshExecutable: clean(env["ASTRA_HOST_CONTROL_SSH_EXECUTABLE"]) ?? "ssh",
            allowedSSHAliases: splitList(env["ASTRA_HOST_CONTROL_ALLOWED_SSH_ALIASES"]),
            diagnosticsHostPath: clean(env["ASTRA_HOST_CONTROL_DIAGNOSTICS_HOST"]) ?? "",
            taskID: clean(env["ASTRA_HOST_CONTROL_TASK_ID"]) ?? "unknown-task",
            runID: clean(env["ASTRA_HOST_CONTROL_RUN_ID"]) ?? "unknown-run",
            connectorsJSON: clean(env["ASTRA_CONNECTORS"]) ?? #"{"connectors":[]}"#,
            environment: env
        )
    }

    public var connectorManifest: HostControlConnectorManifest {
        (try? JSONDecoder().decode(HostControlConnectorManifest.self, from: Data(connectorsJSON.utf8)))
            ?? HostControlConnectorManifest(connectors: [])
    }

    func redacted(_ value: String) -> String {
        secretValues.reduce(value) { current, secret in
            current.replacingOccurrences(of: secret, with: "[redacted]")
        }
    }

    private var secretValues: [String] {
        connectorManifest.connectors.flatMap { connector in
            connector.credentials.values.compactMap { envKey in
                guard isSecretKey(envKey),
                      let value = environment[envKey],
                      value.count >= 4 else { return nil }
                return value
            }
        }
    }

    private func isSecretKey(_ value: String) -> Bool {
        let upper = value.uppercased()
        return upper.contains("TOKEN")
            || upper.contains("SECRET")
            || upper.contains("PASSWORD")
            || upper.contains("API_KEY")
            || upper.contains("CREDENTIAL")
    }

    private static func splitList(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map(String.init)
            .compactMap(clean)
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct HostControlConnectorManifest: Codable, Equatable, Sendable {
    public var connectors: [HostControlConnector]

    public init(connectors: [HostControlConnector]) {
        self.connectors = connectors
    }
}

public struct HostControlConnector: Codable, Equatable, Sendable {
    public var id: String
    public var alias: String
    public var envPrefix: String
    public var name: String
    public var serviceType: String
    public var baseURL: String
    public var authMethod: String
    public var env: [String: String]
    public var credentials: [String: String]
    public var config: [String: String]
}

public struct HostControlCommandResult: Equatable, Sendable {
    public var command: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(
        command: String,
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false
    ) {
        self.command = command
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol HostControlProcessRunning: AnyObject {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        environment: [String: String]
    ) -> HostControlCommandResult
}

public final class HostControlProcessRunner: HostControlProcessRunning {
    public init() {}

    public func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        environment: [String: String]
    ) -> HostControlCommandResult {
        let invocation = commandInvocation(executablePath: executablePath, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments

        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = LockedData()
        let stderrBuffer = LockedData()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutBuffer.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrBuffer.append(data) }
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return HostControlCommandResult(
                command: executablePath,
                arguments: arguments,
                exitCode: 127,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let timedOut = semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
            if process.isRunning {
                process.interrupt()
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())

        return HostControlCommandResult(
            command: executablePath,
            arguments: arguments,
            exitCode: timedOut ? 124 : process.terminationStatus,
            stdout: stdoutBuffer.stringValue,
            stderr: stderrBuffer.stringValue,
            timedOut: timedOut
        )
    }

    private func commandInvocation(executablePath: String, arguments: [String]) -> (executablePath: String, arguments: [String]) {
        if executablePath.contains("/") {
            return (executablePath, arguments)
        }
        return ("/usr/bin/env", [executablePath] + arguments)
    }
}

public final class HostControlToolDiagnosticsRecorder: @unchecked Sendable {
    private let diagnosticsDirectory: URL
    private let fileURL: URL
    private let taskID: String
    private let runID: String
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(configuration: HostControlToolConfiguration, fileManager: FileManager = .default) {
        self.diagnosticsDirectory = URL(fileURLWithPath: configuration.diagnosticsHostPath, isDirectory: true)
        self.fileURL = diagnosticsDirectory.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false)
        self.taskID = configuration.taskID
        self.runID = configuration.runID
        self.fileManager = fileManager
    }

    func record(toolName: String, summary: String, result: HostControlCommandResult?) {
        let redactedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        write(HostControlDiagnosticRecord(
            timestamp: Self.timestamp(),
            taskID: taskID,
            runID: runID,
            route: "host_control_mcp",
            toolName: toolName,
            summary: redactedSummary.isEmpty ? nil : redactedSummary,
            exitCode: result?.exitCode,
            timedOut: result?.timedOut ?? false,
            stderrTail: Self.tail(result?.stderr ?? "")
        ))
    }

    private func write(_ record: HostControlDiagnosticRecord) {
        guard !diagnosticsDirectory.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics are best-effort and must never block a host-control operation.
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func tail(_ value: String, limit: Int = 2_000) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(limit))
    }
}

private struct HostControlDiagnosticRecord: Codable {
    var timestamp: String
    var taskID: String
    var runID: String
    var route: String
    var toolName: String
    var summary: String?
    var exitCode: Int32?
    var timedOut: Bool
    var stderrTail: String?
}

public final class HostControlMCPServer {
    private let configuration: HostControlToolConfiguration
    private let processRunner: HostControlProcessRunning
    private let diagnosticsRecorder: HostControlToolDiagnosticsRecorder?

    public init(
        configuration: HostControlToolConfiguration,
        processRunner: HostControlProcessRunning = HostControlProcessRunner(),
        diagnosticsRecorder: HostControlToolDiagnosticsRecorder? = nil
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
        self.diagnosticsRecorder = diagnosticsRecorder
    }

    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = object["method"] as? String else {
            return encodeError(id: nil, code: -32700, message: "Invalid JSON-RPC request")
        }

        let id = object["id"]
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }
        switch method {
        case "initialize":
            return encodeResult(id: id, result: [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "astra-host-control", "version": "1.0.0"]
            ])
        case "tools/list":
            return encodeResult(id: id, result: [
                "tools": toolSchemas()
            ])
        case "tools/call":
            return handleToolCall(id: id, object: object)
        default:
            return encodeError(id: id, code: -32601, message: "Unsupported method \(method)")
        }
    }

    private func handleToolCall(id: Any?, object: [String: Any]) -> String? {
        guard let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch toolName {
        case "github":
            return handleProcessTool(
                id: id,
                toolName: toolName,
                executable: configuration.githubExecutable,
                arguments: arguments,
                allowedFirstArguments: ["api", "auth", "issue", "pr", "repo", "search", "run", "workflow"]
            )
        case "gcloud":
            return handleProcessTool(
                id: id,
                toolName: toolName,
                executable: configuration.gcloudExecutable,
                arguments: arguments,
                allowedFirstArguments: nil
            )
        case "bq":
            return handleProcessTool(
                id: id,
                toolName: toolName,
                executable: configuration.bigQueryExecutable,
                arguments: arguments,
                allowedFirstArguments: nil,
                argumentPolicy: BigQueryHostControlPolicy.rejectionMessage
            )
        case "ssh":
            return handleSSH(id: id, arguments: arguments)
        case "jira":
            return handleJira(id: id, arguments: arguments)
        default:
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
    }

    private func handleProcessTool(
        id: Any?,
        toolName: String,
        executable: String,
        arguments: [String: Any],
        allowedFirstArguments: Set<String>?,
        argumentPolicy: (([String]) -> String?)? = nil
    ) -> String? {
        guard let argv = stringArray(arguments["arguments"]) else {
            return encodeError(id: id, code: -32602, message: "\(toolName) requires an arguments array")
        }
        guard validateArguments(argv) else {
            return encodeError(id: id, code: -32602, message: "\(toolName) arguments must be non-empty strings without newlines")
        }
        if let allowedFirstArguments,
           let first = argv.first?.lowercased(),
           !allowedFirstArguments.contains(first) {
            return encodeError(id: id, code: -32602, message: "\(toolName) does not allow subcommand '\(first)'")
        }
        if let rejection = argumentPolicy?(argv) {
            return encodeError(id: id, code: -32602, message: rejection)
        }
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"]) ?? 120
        let result = processRunner.run(
            executablePath: executable,
            arguments: argv,
            timeoutSeconds: timeout,
            environment: configuration.environment
        )
        let redacted = redactedResult(result)
        diagnosticsRecorder?.record(
            toolName: toolName,
            summary: "\(toolName) \(argv.joined(separator: " "))",
            result: redacted
        )
        return encodeCommandResult(id: id, result: redacted)
    }

    private func handleSSH(id: Any?, arguments: [String: Any]) -> String? {
        guard let alias = clean(arguments["alias"] as? String) else {
            return encodeError(id: id, code: -32602, message: "ssh requires alias")
        }
        guard validateArguments([alias]) else {
            return encodeError(id: id, code: -32602, message: "ssh alias must be a single non-empty value without newlines")
        }
        let allowed = Set(configuration.allowedSSHAliases)
        if !allowed.isEmpty, !allowed.contains(alias) {
            return encodeError(
                id: id,
                code: -32602,
                message: "ssh alias '\(alias)' is not in ASTRA's configured workspace SSH aliases"
            )
        }
        let remoteCommand = clean(arguments["remote_command"] as? String)
        if let remoteCommand, remoteCommand.contains("\n") {
            return encodeError(id: id, code: -32602, message: "ssh remote_command must not contain newlines")
        }
        var argv = [alias]
        if let remoteCommand {
            argv.append(remoteCommand)
        }
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"]) ?? 120
        let result = processRunner.run(
            executablePath: configuration.sshExecutable,
            arguments: argv,
            timeoutSeconds: timeout,
            environment: configuration.environment
        )
        let redacted = redactedResult(result)
        diagnosticsRecorder?.record(
            toolName: "ssh",
            summary: "ssh \(alias) \(remoteCommand == nil ? "" : "<remote_command>")",
            result: redacted
        )
        return encodeCommandResult(id: id, result: redacted)
    }

    private func handleJira(id: Any?, arguments: [String: Any]) -> String? {
        let operation = (clean(arguments["operation"] as? String) ?? "status").lowercased()
        guard let connector = jiraConnector(alias: clean(arguments["alias"] as? String)) else {
            return encodeError(id: id, code: -32602, message: "No Jira connector is projected into ASTRA_CONNECTORS")
        }
        switch operation {
        case "status":
            let status = jiraStatus(connector: connector)
            diagnosticsRecorder?.record(toolName: "jira", summary: "jira status \(connector.alias)", result: nil)
            return encodeResult(id: id, result: [
                "content": [[
                    "type": "text",
                    "text": formattedJiraStatus(status)
                ]],
                "isError": !status.ready
            ])
        case "request":
            return handleJiraRequest(id: id, connector: connector, arguments: arguments)
        default:
            return encodeError(id: id, code: -32602, message: "Unsupported Jira operation '\(operation)'")
        }
    }

    private func handleJiraRequest(id: Any?, connector: HostControlConnector, arguments: [String: Any]) -> String? {
        let status = jiraStatus(connector: connector)
        guard status.ready else {
            diagnosticsRecorder?.record(toolName: "jira", summary: "jira request \(connector.alias) blocked: not configured", result: nil)
            return encodeResult(id: id, result: [
                "content": [[
                    "type": "text",
                    "text": formattedJiraStatus(status)
                ]],
                "isError": true
            ])
        }
        guard let method = clean(arguments["method"] as? String)?.uppercased(),
              ["GET", "POST", "PUT", "DELETE"].contains(method) else {
            return encodeError(id: id, code: -32602, message: "jira request requires method GET, POST, PUT, or DELETE")
        }
        guard let path = clean(arguments["path"] as? String),
              path.hasPrefix("/") else {
            return encodeError(id: id, code: -32602, message: "jira request requires a path starting with /")
        }
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"]) ?? 120
        let body = clean(arguments["body"] as? String)
        let response = JiraHTTPClient(configuration: configuration).request(
            connector: connector,
            method: method,
            path: path,
            body: body,
            timeoutSeconds: timeout
        )
        diagnosticsRecorder?.record(toolName: "jira", summary: "jira \(method) \(path)", result: response.diagnosticResult)
        return encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": response.formatted(configuration: configuration)
            ]],
            "isError": response.isError
        ])
    }

    private func jiraConnector(alias: String?) -> HostControlConnector? {
        let connectors = configuration.connectorManifest.connectors
            .filter { $0.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "jira" }
        if let alias {
            return connectors.first { $0.alias == alias || $0.name == alias || $0.id == alias }
        }
        return connectors.first
    }

    private func jiraStatus(connector: HostControlConnector) -> JiraConnectorStatus {
        let baseURLReady = URL(string: connector.baseURL)?.scheme?.hasPrefix("http") == true
        let emailKey = envKey(named: "JIRA_EMAIL", in: connector) ?? envKey(named: "EMAIL", in: connector)
        let tokenKey = envKey(named: "JIRA_API_TOKEN", in: connector) ?? envKey(named: "API_TOKEN", in: connector)
        let emailReady = emailKey.flatMap { configuration.environment[$0] }.map { !$0.isEmpty } ?? false
        let tokenReady = tokenKey.flatMap { configuration.environment[$0] }.map { !$0.isEmpty } ?? false
        return JiraConnectorStatus(
            alias: connector.alias,
            baseURL: connector.baseURL,
            baseURLReady: baseURLReady,
            emailEnvKey: emailKey,
            emailReady: emailReady,
            tokenEnvKey: tokenKey,
            tokenReady: tokenReady
        )
    }

    private func envKey(named logicalName: String, in connector: HostControlConnector) -> String? {
        if let key = connector.credentials[logicalName] ?? connector.env[logicalName] {
            return key
        }
        let normalized = logicalName.uppercased()
        return (Array(connector.credentials.values) + Array(connector.env.values)).first {
            $0.uppercased().hasSuffix(normalized) || $0.uppercased() == normalized
        }
    }

    private func formattedJiraStatus(_ status: JiraConnectorStatus) -> String {
        [
            "alias: \(status.alias)",
            "base_url: \(status.baseURLReady ? status.baseURL : "<missing or invalid>")",
            "email_env_key: \(status.emailEnvKey ?? "<missing>")",
            "email_present: \(status.emailReady)",
            "api_token_env_key: \(status.tokenEnvKey ?? "<missing>")",
            "api_token_present: \(status.tokenReady)",
            "ready: \(status.ready)"
        ].joined(separator: "\n")
    }

    private func redactedResult(_ result: HostControlCommandResult) -> HostControlCommandResult {
        HostControlCommandResult(
            command: result.command,
            arguments: result.arguments,
            exitCode: result.exitCode,
            stdout: configuration.redacted(result.stdout),
            stderr: configuration.redacted(result.stderr),
            timedOut: result.timedOut
        )
    }

    private func encodeCommandResult(id: Any?, result: HostControlCommandResult) -> String? {
        encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": formatted(result)
            ]],
            "isError": result.exitCode != 0 || result.timedOut
        ])
    }

    private func formatted(_ result: HostControlCommandResult) -> String {
        var lines = [
            "command: \(URL(fileURLWithPath: result.command).lastPathComponent)",
            "arguments: \(result.arguments.joined(separator: " "))",
            "exit_code: \(result.exitCode)"
        ]
        if result.timedOut {
            lines.append("timed_out: true")
        }
        lines += [
            "stdout:",
            result.stdout.isEmpty ? "<empty>" : result.stdout,
            "stderr:",
            result.stderr.isEmpty ? "<empty>" : result.stderr
        ]
        return lines.joined(separator: "\n")
    }

    private func toolSchemas() -> [[String: Any]] {
        [
            processSchema(
                name: "github",
                description: "Run GitHub CLI control-plane commands on the host through ASTRA without provider Bash.",
                argumentDescription: "Arguments for gh, for example [\"pr\", \"view\", \"123\", \"--comments\"]."
            ),
            processSchema(
                name: "gcloud",
                description: "Run Google Cloud CLI control-plane commands on the host through ASTRA without provider Bash.",
                argumentDescription: "Arguments for gcloud, for example [\"compute\", \"instances\", \"list\", \"--format=json\"]."
            ),
            processSchema(
                name: "bq",
                description: "Run BigQuery CLI help/version commands on the host through ASTRA without provider Bash.",
                argumentDescription: "Help-only bq arguments, for example [\"--help\"], [\"help\"], or [\"version\"]. Resource listing, display, query, export, load, delete, copy, table mutation, and job commands are denied."
            ),
            sshSchema(),
            jiraSchema()
        ]
    }

    private func processSchema(name: String, description: String, argumentDescription: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "arguments": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": argumentDescription
                    ],
                    "timeout_seconds": [
                        "type": "number",
                        "description": "Optional command timeout. Defaults to 120 seconds."
                    ]
                ],
                "required": ["arguments"],
                "additionalProperties": false
            ]
        ]
    }

    private func sshSchema() -> [String: Any] {
        [
            "name": "ssh",
            "description": "Run a configured workspace SSH alias on the host through ASTRA without provider Bash.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "alias": ["type": "string", "description": "Configured SSH Host alias or workspace SSH connection alias."],
                    "remote_command": ["type": "string", "description": "Optional remote command passed to ssh as one argument."],
                    "timeout_seconds": ["type": "number", "description": "Optional command timeout. Defaults to 120 seconds."]
                ],
                "required": ["alias"],
                "additionalProperties": false
            ]
        ]
    }

    private func jiraSchema() -> [String: Any] {
        [
            "name": "jira",
            "description": "Use ASTRA-projected Jira connector credentials on the host. Status never reveals secret values.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "operation": ["type": "string", "description": "status or request. Defaults to status."],
                    "alias": ["type": "string", "description": "Optional connector alias."],
                    "method": ["type": "string", "description": "For request: GET, POST, PUT, or DELETE."],
                    "path": ["type": "string", "description": "For request: Jira REST path beginning with /."],
                    "body": ["type": "string", "description": "For request: optional JSON body."],
                    "timeout_seconds": ["type": "number", "description": "Optional request timeout. Defaults to 120 seconds."]
                ],
                "additionalProperties": false
            ]
        ]
    }

    private func stringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { $0 as? String }
    }

    private func validateArguments(_ values: [String]) -> Bool {
        !values.isEmpty && values.allSatisfy {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !$0.contains("\n") && !$0.contains("\r")
        }
    }

    private func timeoutSeconds(from value: Any?) -> TimeInterval? {
        switch value {
        case let number as NSNumber:
            return max(1, number.doubleValue)
        case let value as String:
            return Double(value).map { max(1, $0) }
        default:
            return nil
        }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func encodeResult(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": normalizedID(id), "result": result])
    }

    private func encodeError(id: Any?, code: Int, message: String) -> String? {
        encode([
            "jsonrpc": "2.0",
            "id": normalizedID(id),
            "error": ["code": code, "message": message]
        ])
    }

    private func normalizedID(_ id: Any?) -> Any {
        switch id {
        case let value as String: return value
        case let value as NSNumber: return value
        case .none: return NSNull()
        default: return NSNull()
        }
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private enum BigQueryHostControlPolicy {
    private static let allowedCommands: Set<String> = ["help", "version"]
    private static let helpOptions: Set<String> = ["--help", "-h"]
    private static let versionOptions: Set<String> = ["--version"]
    private static let globalOptionsWithValues: Set<String> = [
        "--format",
        "--location",
        "--max_results",
        "--page_token",
        "--project_id"
    ]

    static func rejectionMessage(arguments: [String]) -> String? {
        let actionTokens = dropLeadingOptions(arguments)
        guard let command = actionTokens.first?.lowercased() else {
            if isBareHelpOrVersion(arguments) {
                return nil
            }
            return blockedMessage(command: "<missing>")
        }
        guard allowedCommands.contains(command) else {
            return blockedMessage(command: command)
        }
        return nil
    }

    private static func dropLeadingOptions(_ arguments: [String]) -> [String] {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-") else { break }
            index += 1
            let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if globalOptionsWithValues.contains(optionName), !token.contains("="), index < arguments.count {
                index += 1
            }
        }
        return Array(arguments.dropFirst(index))
    }

    private static func isBareHelpOrVersion(_ arguments: [String]) -> Bool {
        !arguments.isEmpty && arguments.allSatisfy { token in
            let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            return helpOptions.contains(optionName) || versionOptions.contains(optionName)
        }
    }

    private static func blockedMessage(command: String) -> String {
        [
            "bq command is not allowed by ASTRA host-control policy: '\(command)'.",
            "Allowed bq operations are help/version only: help and version commands, or bare --help, -h, and --version flags.",
            "Use an explicitly approved BigQuery capability for query, export, load, delete, copy, table mutation, or job operations."
        ].joined(separator: " ")
    }
}

private struct JiraConnectorStatus {
    var alias: String
    var baseURL: String
    var baseURLReady: Bool
    var emailEnvKey: String?
    var emailReady: Bool
    var tokenEnvKey: String?
    var tokenReady: Bool

    var ready: Bool {
        baseURLReady && emailReady && tokenReady
    }
}

private struct JiraHTTPResponse {
    var statusCode: Int
    var body: String
    var errorMessage: String?

    var isError: Bool {
        if errorMessage != nil { return true }
        return statusCode < 200 || statusCode >= 300
    }

    var diagnosticResult: HostControlCommandResult {
        HostControlCommandResult(
            command: "jira",
            arguments: ["request"],
            exitCode: isError ? 1 : 0,
            stdout: body,
            stderr: errorMessage ?? ""
        )
    }

    func formatted(configuration: HostControlToolConfiguration) -> String {
        [
            "status_code: \(statusCode)",
            "body:",
            body.isEmpty ? "<empty>" : configuration.redacted(body),
            "error:",
            errorMessage.map(configuration.redacted) ?? "<empty>"
        ].joined(separator: "\n")
    }
}

private final class JiraHTTPClient {
    private let configuration: HostControlToolConfiguration

    init(configuration: HostControlToolConfiguration) {
        self.configuration = configuration
    }

    func request(
        connector: HostControlConnector,
        method: String,
        path: String,
        body: String?,
        timeoutSeconds: TimeInterval
    ) -> JiraHTTPResponse {
        guard let url = URL(string: connector.baseURL)?.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Invalid Jira base URL or path")
        }
        guard let email = credential(named: "JIRA_EMAIL", connector: connector) ?? credential(named: "EMAIL", connector: connector),
              let token = credential(named: "JIRA_API_TOKEN", connector: connector) ?? credential(named: "API_TOKEN", connector: connector) else {
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Jira connector credentials are not projected")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let tokenData = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(tokenData)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        var result = JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Request did not complete")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            result = JiraHTTPResponse(statusCode: statusCode, body: body, errorMessage: error?.localizedDescription)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Timed out after \(Int(timeoutSeconds))s")
        }
        return result
    }

    private func credential(named logicalName: String, connector: HostControlConnector) -> String? {
        let upper = logicalName.uppercased()
        let envKey = connector.credentials[logicalName]
            ?? connector.env[logicalName]
            ?? (Array(connector.credentials.values) + Array(connector.env.values)).first {
                $0.uppercased().hasSuffix(upper) || $0.uppercased() == upper
            }
        guard let envKey,
              let value = configuration.environment[envKey],
              !value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

public enum AstraHostControlToolMain {
    public static func run() {
        let configuration = HostControlToolConfiguration.fromEnvironment()
        let recorder = HostControlToolDiagnosticsRecorder(configuration: configuration)
        let server = HostControlMCPServer(configuration: configuration, diagnosticsRecorder: recorder)
        while let line = readLine() {
            if let response = server.handleLine(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? String(decoding: snapshot, as: UTF8.self)
    }
}
