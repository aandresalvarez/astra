import Foundation

public struct WorkspaceDockerMount: Codable, Equatable, Sendable {
    public var hostPath: String
    public var containerPath: String
    public var access: String
    public var role: String

    public init(hostPath: String, containerPath: String, access: String, role: String) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.access = access
        self.role = role
    }
}

public struct WorkspaceToolConfiguration: Equatable, Sendable {
    public var dockerExecutable: String
    public var image: String
    public var containerName: String
    public var workdir: String
    public var network: String
    public var taskID: String
    public var runID: String
    public var mounts: [WorkspaceDockerMount]
    public var containerEnvironment: [String: String]

    public init(
        dockerExecutable: String,
        image: String,
        containerName: String,
        workdir: String,
        network: String,
        taskID: String,
        runID: String,
        mounts: [WorkspaceDockerMount],
        containerEnvironment: [String: String] = [:]
    ) {
        self.dockerExecutable = dockerExecutable
        self.image = image
        self.containerName = containerName
        self.workdir = workdir
        self.network = network
        self.taskID = taskID
        self.runID = runID
        self.mounts = mounts
        self.containerEnvironment = Self.normalizedContainerEnvironment(containerEnvironment)
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> WorkspaceToolConfiguration {
        let dockerExecutable = clean(env["ASTRA_WORKSPACE_DOCKER_EXECUTABLE"]) ?? "docker"
        guard let image = clean(env["ASTRA_WORKSPACE_DOCKER_IMAGE"]) else {
            throw WorkspaceToolError("ASTRA_WORKSPACE_DOCKER_IMAGE is required")
        }
        guard let containerName = clean(env["ASTRA_WORKSPACE_DOCKER_CONTAINER"]) else {
            throw WorkspaceToolError("ASTRA_WORKSPACE_DOCKER_CONTAINER is required")
        }
        let workdir = clean(env["ASTRA_WORKSPACE_DOCKER_WORKDIR"]) ?? "/workspace"
        let network = clean(env["ASTRA_WORKSPACE_DOCKER_NETWORK"]) ?? "bridge"
        let taskID = clean(env["ASTRA_WORKSPACE_TASK_ID"]) ?? "unknown-task"
        let runID = clean(env["ASTRA_WORKSPACE_RUN_ID"]) ?? "unknown-run"
        let mountsJSON = clean(env["ASTRA_WORKSPACE_DOCKER_MOUNTS"]) ?? "[]"
        let data = Data(mountsJSON.utf8)
        let mounts = (try? JSONDecoder().decode([WorkspaceDockerMount].self, from: data)) ?? []
        guard !mounts.isEmpty else {
            throw WorkspaceToolError("ASTRA_WORKSPACE_DOCKER_MOUNTS must contain at least the workspace mount")
        }
        let containerEnvironmentJSON = clean(env["ASTRA_WORKSPACE_DOCKER_ENV"]) ?? "{}"
        let containerEnvironmentData = Data(containerEnvironmentJSON.utf8)
        let decodedContainerEnvironment = (try? JSONDecoder().decode([String: String].self, from: containerEnvironmentData)) ?? [:]
        return WorkspaceToolConfiguration(
            dockerExecutable: dockerExecutable,
            image: image,
            containerName: containerName,
            workdir: workdir,
            network: network,
            taskID: taskID,
            runID: runID,
            mounts: mounts,
            containerEnvironment: decodedContainerEnvironment
        )
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedContainerEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [String: String]()) { result, pair in
            let (key, value) = pair
            let cleanedKey = cleanEnvironmentKey(key)
            guard !cleanedKey.isEmpty else { return }
            let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedValue.isEmpty else { return }
            result[cleanedKey] = cleanedValue
        }
    }

    private static func cleanEnvironmentKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return ""
        }
        return trimmed
    }
}

public struct WorkspaceCommandResult: Equatable, Sendable {
    public var command: String
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(command: String, exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol WorkspaceCommandExecutor: AnyObject {
    func run(command: String, timeoutSeconds: TimeInterval) -> WorkspaceCommandResult
    func cleanup()
}

public final class DockerWorkspaceCommandExecutor: WorkspaceCommandExecutor {
    private let configuration: WorkspaceToolConfiguration
    private var containerStarted = false

    public init(configuration: WorkspaceToolConfiguration) {
        self.configuration = configuration
    }

    public func run(command: String, timeoutSeconds: TimeInterval) -> WorkspaceCommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WorkspaceCommandResult(command: command, exitCode: 2, stdout: "", stderr: "workspace_shell requires a non-empty command")
        }
        let start = ensureContainer()
        guard start.exitCode == 0 else {
            return WorkspaceCommandResult(
                command: command,
                exitCode: start.exitCode,
                stdout: start.stdout,
                stderr: start.stderr.isEmpty ? "Failed to start Docker workspace container" : start.stderr,
                timedOut: start.timedOut
            )
        }
        return runDocker(
            ["exec", "-i", "--workdir", configuration.workdir, configuration.containerName, "sh", "-c", trimmed],
            commandLabel: command,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func cleanup() {
        guard containerStarted else { return }
        _ = runDocker(["stop", configuration.containerName], commandLabel: "docker stop", timeoutSeconds: 10)
        containerStarted = false
    }

    private func ensureContainer() -> WorkspaceCommandResult {
        let inspect = runDocker(
            ["inspect", "-f", "{{.State.Running}}", configuration.containerName],
            commandLabel: "docker inspect",
            timeoutSeconds: 5
        )
        if inspect.exitCode == 0,
           inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            containerStarted = true
            return inspect
        }
        containerStarted = false

        _ = runDocker(["rm", "-f", configuration.containerName], commandLabel: "docker rm", timeoutSeconds: 10)

        var args = [
            "run", "--rm", "-d",
            "--name", configuration.containerName,
            "--label", "com.coral.astra.workspace_executor=true",
            "--label", "com.coral.astra.task=\(configuration.taskID)",
            "--label", "com.coral.astra.run=\(configuration.runID)",
            "--workdir", configuration.workdir,
            "--network", configuration.network
        ]
        for mount in configuration.mounts {
            args += ["--volume", "\(mount.hostPath):\(mount.containerPath):\(mount.access)"]
        }
        for key in configuration.containerEnvironment.keys.sorted() {
            args += ["--env", key]
        }
        args += [configuration.image, "sh", "-c", "while :; do sleep 3600; done"]

        let result = runDocker(
            args,
            commandLabel: "docker run",
            timeoutSeconds: 30,
            environment: configuration.containerEnvironment
        )
        if result.exitCode == 0 {
            containerStarted = true
        }
        return result
    }

    private func runDocker(
        _ arguments: [String],
        commandLabel: String,
        timeoutSeconds: TimeInterval,
        environment: [String: String] = [:]
    ) -> WorkspaceCommandResult {
        let invocation = dockerInvocation(arguments)
        return ProcessRunner.run(
            executablePath: invocation.executablePath,
            arguments: invocation.arguments,
            commandLabel: commandLabel,
            timeoutSeconds: timeoutSeconds,
            environment: environment
        )
    }

    private func dockerInvocation(_ arguments: [String]) -> DockerProcessInvocation {
        DockerProcessInvocation.resolve(
            dockerExecutable: configuration.dockerExecutable,
            arguments: arguments
        )
    }
}

struct DockerProcessInvocation: Equatable, Sendable {
    var executablePath: String
    var arguments: [String]

    static func resolve(dockerExecutable: String, arguments: [String]) -> DockerProcessInvocation {
        if dockerExecutable.hasPrefix("/") {
            return DockerProcessInvocation(executablePath: dockerExecutable, arguments: arguments)
        }
        return DockerProcessInvocation(executablePath: "/usr/bin/env", arguments: [dockerExecutable] + arguments)
    }
}

public final class WorkspaceMCPServer {
    private let executor: WorkspaceCommandExecutor

    public init(executor: WorkspaceCommandExecutor) {
        self.executor = executor
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
                "serverInfo": ["name": "astra-workspace", "version": "1.0.0"]
            ])
        case "tools/list":
            return encodeResult(id: id, result: [
                "tools": [[
                    "name": "workspace_shell",
                    "description": "Run a shell command inside the ASTRA-managed Docker workspace container using the image environment. Check tools by name from the container PATH and avoid host-created virtual environments from bind-mounted workspaces.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "Shell command to run from the container workspace directory."
                            ],
                            "timeout_seconds": [
                                "type": "number",
                                "description": "Optional command timeout. Defaults to 120 seconds."
                            ]
                        ],
                        "required": ["command"],
                        "additionalProperties": false
                    ]
                ]]
            ])
        case "tools/call":
            return handleToolCall(id: id, object: object)
        default:
            return encodeError(id: id, code: -32601, message: "Unsupported method \(method)")
        }
    }

    public func cleanup() {
        executor.cleanup()
    }

    private func handleToolCall(id: Any?, object: [String: Any]) -> String? {
        guard let params = object["params"] as? [String: Any],
              params["name"] as? String == "workspace_shell" else {
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let command = arguments["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encodeError(id: id, code: -32602, message: "workspace_shell requires command")
        }
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"]) ?? 120
        let result = executor.run(command: command, timeoutSeconds: timeout)
        return encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": formatted(result)
            ]],
            "isError": result.exitCode != 0 || result.timedOut
        ])
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

    private func formatted(_ result: WorkspaceCommandResult) -> String {
        var lines = [
            "command: \(result.command)",
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

public enum AstraWorkspaceToolMain {
    public static func run() {
        do {
            let configuration = try WorkspaceToolConfiguration.fromEnvironment()
            let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
            let server = WorkspaceMCPServer(executor: executor)
            defer { server.cleanup() }
            while let line = readLine() {
                if let response = server.handleLine(line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            }
        } catch {
            let server = WorkspaceMCPServer(executor: FailingWorkspaceCommandExecutor(message: error.localizedDescription))
            while let line = readLine() {
                if let response = server.handleLine(line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            }
        }
    }
}

private final class FailingWorkspaceCommandExecutor: WorkspaceCommandExecutor {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func run(command: String, timeoutSeconds _: TimeInterval) -> WorkspaceCommandResult {
        WorkspaceCommandResult(command: command, exitCode: 2, stdout: "", stderr: message)
    }

    func cleanup() {}
}

public struct WorkspaceToolError: LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

private enum ProcessRunner {
    static func run(
        executablePath: String,
        arguments: [String],
        commandLabel: String,
        timeoutSeconds: TimeInterval,
        environment: [String: String] = [:]
    ) -> WorkspaceCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
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
            return WorkspaceCommandResult(
                command: commandLabel,
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

        return WorkspaceCommandResult(
            command: commandLabel,
            exitCode: timedOut ? 124 : process.terminationStatus,
            stdout: stdoutBuffer.stringValue,
            stderr: stderrBuffer.stringValue,
            timedOut: timedOut
        )
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
