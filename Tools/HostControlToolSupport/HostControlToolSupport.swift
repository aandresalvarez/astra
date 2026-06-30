import Darwin
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

    func redacted(_ value: String, includingSecretFragments: Bool = false) -> String {
        let secrets = secretValues
        let redacted = secrets.reduce(value) { current, secret in
            current.replacingOccurrences(of: secret, with: "[redacted]")
        }
        guard includingSecretFragments else { return redacted }
        return redactedSecretPrefixes(redacted, secrets: secrets)
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

    private func redactedSecretPrefixes(_ value: String, secrets: [String]) -> String {
        let redaction = Array("[redacted]".utf8)
        let source = Array(value.utf8)
        let ranges = mergedSecretPrefixRanges(in: source, secrets: secrets.map { Array($0.utf8) })
        guard !ranges.isEmpty else { return value }

        var output: [UInt8] = []
        output.reserveCapacity(source.count)
        var cursor = 0
        for range in ranges {
            guard range.lowerBound >= cursor else { continue }
            output.append(contentsOf: source[cursor..<range.lowerBound])
            output.append(contentsOf: redaction)
            cursor = range.upperBound
        }
        output.append(contentsOf: source[cursor..<source.count])
        return String(decoding: output, as: UTF8.self)
    }

    private func mergedSecretPrefixRanges(in value: [UInt8], secrets: [[UInt8]]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for secret in secrets where secret.count >= 4 {
            appendShortTruncatedSecretPrefixRanges(in: value, secret: secret, to: &ranges)

            var index = 0
            while index + 4 <= value.count {
                guard value[index] == secret[0],
                      value[index + 1] == secret[1],
                      value[index + 2] == secret[2],
                      value[index + 3] == secret[3] else {
                    index += 1
                    continue
                }

                let maximumLength = min(secret.count, value.count - index)
                var length = 4
                while length < maximumLength, value[index + length] == secret[length] {
                    length += 1
                }
                ranges.append(index..<index + length)
                index += length
            }
        }

        guard !ranges.isEmpty else { return [] }
        return ranges.sorted { lhs, rhs in
            lhs.lowerBound == rhs.lowerBound ? lhs.upperBound < rhs.upperBound : lhs.lowerBound < rhs.lowerBound
        }.reduce(into: []) { merged, range in
            guard let last = merged.last else {
                merged.append(range)
                return
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
    }

    private func appendShortTruncatedSecretPrefixRanges(
        in value: [UInt8],
        secret: [UInt8],
        to ranges: inout [Range<Int>]
    ) {
        guard !value.isEmpty else { return }
        let maximumShortPrefixLength = min(3, secret.count)
        for index in value.indices {
            let remainingLength = value.count - index
            guard remainingLength > 0 else { continue }
            let candidateMaximumLength = min(maximumShortPrefixLength, remainingLength)
            for length in stride(from: candidateMaximumLength, through: 1, by: -1) {
                let range = index..<index + length
                guard Array(value[range]) == Array(secret.prefix(length)),
                      isTruncatedOutputBoundary(after: range.upperBound, in: value) else {
                    continue
                }
                ranges.append(range)
                break
            }
        }
    }

    private func isTruncatedOutputBoundary(after index: Int, in value: [UInt8]) -> Bool {
        guard index < value.count else { return true }
        let marker = Array("\n[ASTRA truncated ".utf8)
        guard index + marker.count <= value.count else { return false }
        return Array(value[index..<index + marker.count]) == marker
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
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        command: String,
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.command = command
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public struct HostControlProcessLimits: Equatable, Sendable {
    public static let standard = HostControlProcessLimits()
    private static let defaultMaximumTimeoutSeconds: TimeInterval = 300

    public var maximumTimeoutSeconds: TimeInterval
    public var outputByteLimit: Int

    public init(
        maximumTimeoutSeconds: TimeInterval = 300,
        outputByteLimit: Int = 256 * 1024
    ) {
        let finiteMaximum = maximumTimeoutSeconds.isFinite ? maximumTimeoutSeconds : Self.defaultMaximumTimeoutSeconds
        self.maximumTimeoutSeconds = max(1, finiteMaximum)
        self.outputByteLimit = max(1, outputByteLimit)
    }

    func clampedTimeout(_ requested: TimeInterval) -> TimeInterval {
        let finiteRequest = requested.isFinite ? requested : maximumTimeoutSeconds
        return min(max(1, finiteRequest), maximumTimeoutSeconds)
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
    private let limits: HostControlProcessLimits
    private let outputLimitGraceSeconds: TimeInterval = 0.5
    private let timeoutGraceSeconds: TimeInterval = 2

    public init(limits: HostControlProcessLimits = .standard) {
        self.limits = limits
    }

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
        let stdoutBuffer = BoundedProcessOutput(label: "stdout", byteLimit: limits.outputByteLimit)
        let stderrBuffer = BoundedProcessOutput(label: "stderr", byteLimit: limits.outputByteLimit)
        let outputLimitExceeded = LockedFlag()
        process.standardOutput = stdout
        process.standardError = stderr

        let terminateForOutputLimit: () -> Void = {
            if outputLimitExceeded.setIfUnset() {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            guard !stdoutBuffer.isTruncated else {
                self.stopReading(handle)
                return
            }
            let data = handle.availableData
            if stdoutBuffer.append(data) {
                self.stopReading(handle)
                terminateForOutputLimit()
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            guard !stderrBuffer.isTruncated else {
                self.stopReading(handle)
                return
            }
            let data = handle.availableData
            if stderrBuffer.append(data) {
                self.stopReading(handle)
                terminateForOutputLimit()
            }
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

        let waitOutcome = waitForProcess(
            semaphore: semaphore,
            timeoutSeconds: limits.clampedTimeout(timeoutSeconds),
            outputLimitExceeded: outputLimitExceeded
        )
        let timedOut = waitOutcome == .timedOut
        switch waitOutcome {
        case .exited:
            break
        case .outputLimited:
            stopProcess(process, semaphore: semaphore, graceSeconds: outputLimitGraceSeconds)
        case .timedOut:
            stopProcess(process, semaphore: semaphore, graceSeconds: timeoutGraceSeconds)
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        drainPipe(stdout.fileHandleForReading, into: stdoutBuffer, onLimitExceeded: terminateForOutputLimit)
        drainPipe(stderr.fileHandleForReading, into: stderrBuffer, onLimitExceeded: terminateForOutputLimit)

        let outputTruncated = outputLimitExceeded.isSet || stdoutBuffer.isTruncated || stderrBuffer.isTruncated

        return HostControlCommandResult(
            command: executablePath,
            arguments: arguments,
            exitCode: timedOut ? 124 : outputTruncated ? 125 : process.terminationStatus,
            stdout: stdoutBuffer.stringValue,
            stderr: stderrBuffer.stringValue,
            timedOut: timedOut,
            stdoutTruncated: stdoutBuffer.isTruncated,
            stderrTruncated: stderrBuffer.isTruncated
        )
    }

    private enum ProcessWaitOutcome {
        case exited
        case outputLimited
        case timedOut
    }

    private func waitForProcess(
        semaphore: DispatchSemaphore,
        timeoutSeconds: TimeInterval,
        outputLimitExceeded: LockedFlag
    ) -> ProcessWaitOutcome {
        let deadline = DispatchTime.now() + dispatchInterval(seconds: timeoutSeconds)
        while true {
            if semaphore.wait(timeout: .now() + 0.05) == .success {
                return .exited
            }
            if outputLimitExceeded.isSet {
                return .outputLimited
            }
            if DispatchTime.now() >= deadline {
                return .timedOut
            }
        }
    }

    private func dispatchInterval(seconds: TimeInterval) -> DispatchTimeInterval {
        let milliseconds = max(1, Int((seconds * 1_000).rounded(.up)))
        return .milliseconds(milliseconds)
    }

    private func stopProcess(_ process: Process, semaphore: DispatchSemaphore, graceSeconds: TimeInterval) {
        guard process.isRunning else { return }
        process.terminate()
        if semaphore.wait(timeout: .now() + graceSeconds) == .success {
            return
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + 1)
        }
    }

    private func stopReading(_ handle: FileHandle) {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func drainPipe(
        _ handle: FileHandle,
        into buffer: BoundedProcessOutput,
        onLimitExceeded: () -> Void
    ) {
        guard !buffer.isTruncated else {
            stopReading(handle)
            return
        }
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            stopReading(handle)
            return
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            stopReading(handle)
            return
        }

        var bytes = [UInt8](repeating: 0, count: 8192)
        defer { stopReading(handle) }
        while true {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            let data = Data(bytes.prefix(count))
            if buffer.append(data) {
                onLimitExceeded()
                return
            }
        }
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
    private let processLimits: HostControlProcessLimits

    public init(
        configuration: HostControlToolConfiguration,
        processRunner: HostControlProcessRunning? = nil,
        diagnosticsRecorder: HostControlToolDiagnosticsRecorder? = nil,
        processLimits: HostControlProcessLimits = .standard
    ) {
        self.configuration = configuration
        self.processRunner = processRunner ?? HostControlProcessRunner(limits: processLimits)
        self.diagnosticsRecorder = diagnosticsRecorder
        self.processLimits = processLimits
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
                allowedFirstArguments: nil
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
        allowedFirstArguments: Set<String>?
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
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"])
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
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"])
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
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"])
        let body = clean(arguments["body"] as? String)
        let response = JiraHTTPClient(configuration: configuration).request(
            connector: connector,
            method: method,
            path: path,
            body: body,
            timeoutSeconds: timeout,
            outputByteLimit: processLimits.outputByteLimit
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
        let includeSecretFragments = result.stdoutTruncated || result.stderrTruncated || result.timedOut
        let stdout = configuration.redacted(result.stdout, includingSecretFragments: includeSecretFragments)
        let stderr = configuration.redacted(result.stderr, includingSecretFragments: includeSecretFragments)
        return HostControlCommandResult(
            command: result.command,
            arguments: result.arguments,
            exitCode: result.exitCode,
            stdout: cappedRedactedOutput(stdout, label: "stdout", wasTruncated: result.stdoutTruncated),
            stderr: cappedRedactedOutput(stderr, label: "stderr", wasTruncated: result.stderrTruncated),
            timedOut: result.timedOut,
            stdoutTruncated: result.stdoutTruncated,
            stderrTruncated: result.stderrTruncated
        )
    }

    private func cappedRedactedOutput(_ value: String, label: String, wasTruncated: Bool) -> String {
        guard wasTruncated else { return value }
        let bytes = Array(value.utf8)
        let byteLimit = processLimits.outputByteLimit
        guard bytes.count > byteLimit else { return value }

        let marker = Array("\n[ASTRA redacted \(label) output capped after \(byteLimit) bytes]\n".utf8)
        let markerCount = min(byteLimit, marker.count)
        let prefixCount = max(0, byteLimit - markerCount)
        var capped = Array(bytes.prefix(prefixCount))
        capped.append(contentsOf: marker.prefix(byteLimit - capped.count))
        return String(decoding: capped, as: UTF8.self)
    }

    private func encodeCommandResult(id: Any?, result: HostControlCommandResult) -> String? {
        encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": formatted(result)
            ]],
            "isError": result.exitCode != 0 || result.timedOut || result.stdoutTruncated || result.stderrTruncated
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
        if result.stdoutTruncated || result.stderrTruncated {
            lines.append("output_truncated: true")
        }
        if result.stdoutTruncated {
            lines.append("stdout_truncated: true")
        }
        if result.stderrTruncated {
            lines.append("stderr_truncated: true")
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
                description: "Run BigQuery CLI control-plane commands on the host through ASTRA without provider Bash.",
                argumentDescription: "Arguments for bq, for example [\"ls\", \"project:dataset\"]."
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
                        "description": timeoutDescription(kind: "command")
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
                    "timeout_seconds": ["type": "number", "description": timeoutDescription(kind: "command")]
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
                    "timeout_seconds": ["type": "number", "description": timeoutDescription(kind: "request")]
                ],
                "additionalProperties": false
            ]
        ]
    }

    private func timeoutDescription(kind: String) -> String {
        let defaultTimeout = min(120, processLimits.maximumTimeoutSeconds)
        return "Optional \(kind) timeout. Defaults to \(formattedSeconds(defaultTimeout)) seconds and is capped at \(formattedSeconds(processLimits.maximumTimeoutSeconds)) seconds."
    }

    private func formattedSeconds(_ value: TimeInterval) -> String {
        if value.rounded(.towardZero) == value {
            return "\(Int(value))"
        }
        return "\(value)"
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

    private func timeoutSeconds(from value: Any?) -> TimeInterval {
        let requested: TimeInterval? = switch value {
        case let number as NSNumber:
            number.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
        let finiteRequest = requested.flatMap { $0.isFinite ? $0 : nil }
        return processLimits.clampedTimeout(finiteRequest ?? 120)
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
    var bodyTruncated: Bool = false

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
            stderr: errorMessage ?? "",
            stdoutTruncated: bodyTruncated
        )
    }

    func formatted(configuration: HostControlToolConfiguration) -> String {
        var lines = [
            "status_code: \(statusCode)",
            "body:",
            body.isEmpty ? "<empty>" : configuration.redacted(body),
            "error:",
            errorMessage.map { configuration.redacted($0) } ?? "<empty>"
        ]
        if bodyTruncated {
            lines.insert("body_truncated: true", at: 1)
        }
        return lines.joined(separator: "\n")
    }
}

private final class BoundedJiraHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let buffer: BoundedProcessOutput
    private let lock = NSLock()
    private var statusCode = 0
    private var errorMessage: String?
    private var bodyTruncated = false

    init(semaphore: DispatchSemaphore, outputByteLimit: Int) {
        self.semaphore = semaphore
        self.buffer = BoundedProcessOutput(label: "Jira response body", byteLimit: outputByteLimit)
    }

    var response: JiraHTTPResponse {
        lock.lock()
        let snapshot = JiraHTTPResponse(
            statusCode: statusCode,
            body: buffer.stringValue,
            errorMessage: errorMessage,
            bodyTruncated: bodyTruncated
        )
        lock.unlock()
        return snapshot
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if buffer.append(data) {
            lock.lock()
            bodyTruncated = true
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            if !bodyTruncated {
                errorMessage = error.localizedDescription
            }
            lock.unlock()
        }
        semaphore.signal()
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
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int
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
        let delegate = BoundedJiraHTTPDelegate(semaphore: semaphore, outputByteLimit: outputByteLimit)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Timed out after \(Int(timeoutSeconds))s")
        }
        session.finishTasksAndInvalidate()
        return delegate.response
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }

    var isSet: Bool {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private static let truncationBoundarySafetyBytes = 512

    private let lock = NSLock()
    private let label: String
    private let byteLimit: Int
    private var data = Data()
    private var truncated = false

    init(label: String, byteLimit: Int) {
        self.label = label
        self.byteLimit = byteLimit
    }

    func append(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }

        guard !truncated else { return false }
        let remaining = max(0, byteLimit - data.count)
        if remaining >= chunk.count {
            data.append(chunk)
            return false
        }
        let marker = "\n[ASTRA truncated \(label) after \(byteLimit) bytes]\n"
        let markerData = Data(marker.utf8)
        let markerBytesToKeep = min(byteLimit, markerData.count)
        let outputBytesToKeep = max(0, byteLimit - markerBytesToKeep - Self.truncationBoundarySafetyBytes)
        if data.count < outputBytesToKeep {
            data.append(chunk.prefix(outputBytesToKeep - data.count))
        }
        if data.count > outputBytesToKeep {
            data.removeLast(data.count - outputBytesToKeep)
        }
        data.append(markerData.prefix(byteLimit - data.count))
        truncated = true
        return true
    }

    var isTruncated: Bool {
        lock.lock()
        let snapshot = truncated
        lock.unlock()
        return snapshot
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? String(decoding: snapshot, as: UTF8.self)
    }
}
