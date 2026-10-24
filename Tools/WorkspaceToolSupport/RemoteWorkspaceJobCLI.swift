import Foundation

/// `astra-workspace-job`: the SSH workspace counterpart of the Docker
/// workspace's `workspace_job_start` / `_status` / `_tail` tools, as a shell
/// command because the route it extends is the provider's shell.
///
/// Output is `key: value` lines like the Docker tool's, keyed by
/// `remote_job_id` rather than `job_id`: the process monitor reads `job_id`
/// plus `status` as an in-turn managed job and suspends the run's watchdogs
/// for it, and a remote job is meant to outlive the turn, not hold it open.
public enum RemoteWorkspaceJobCLI {
    public static let commandName = "astra-workspace-job"

    public enum Command: Equatable, Sendable {
        case start(connection: String?, label: String?, timeoutSeconds: Int?, command: String)
        case status(jobID: String)
        case tail(jobID: String, stream: String, lines: Int)
        case help
    }

    public struct Output: Equatable, Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(arguments: [String], environment: [String: String]) -> Output {
        let command: Command
        do {
            command = try parse(arguments)
        } catch {
            return Output(exitCode: 2, stdout: "", stderr: "\(error.localizedDescription)\n\n\(usage)\n")
        }
        if command == .help {
            return Output(exitCode: 0, stdout: usage + "\n", stderr: "")
        }
        let configuration: RemoteWorkspaceJobConfiguration
        do {
            configuration = try RemoteWorkspaceJobConfiguration.fromEnvironment(environment)
        } catch {
            return Output(exitCode: 1, stdout: "", stderr: error.localizedDescription + "\n")
        }
        return run(command, manager: RemoteWorkspaceJobManager(configuration: configuration))
    }

    public static func run(_ command: Command, manager: RemoteWorkspaceJobManager) -> Output {
        switch command {
        case .help:
            return Output(exitCode: 0, stdout: usage + "\n", stderr: "")
        case .start(let connection, let label, let timeoutSeconds, let remoteCommand):
            return output(manager.start(
                connectionTarget: connection,
                command: remoteCommand,
                label: label,
                timeoutSeconds: timeoutSeconds
            ), store: manager.store)
        case .status(let jobID):
            return output(manager.status(jobID: jobID), store: manager.store)
        case .tail(let jobID, let stream, let lines):
            switch manager.tail(jobID: jobID, stream: stream, lines: lines) {
            case .text(let jobID, let stream, let text):
                let body = [
                    "remote_job_id: \(jobID)",
                    "stream: \(stream)",
                    text.isEmpty ? "<empty>" : text
                ].joined(separator: "\n")
                return Output(exitCode: 0, stdout: body + "\n", stderr: "")
            case .failure(let message):
                return Output(exitCode: 1, stdout: "", stderr: message + "\n")
            }
        }
    }

    // MARK: - Parsing

    public static func parse(_ arguments: [String]) throws -> Command {
        guard let subcommand = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "start":
            return try parseStart(rest)
        case "status":
            let (positionals, _) = try options(rest, allowed: [])
            guard positionals.count == 1 else { throw usageError("status takes exactly one remote_job_id.") }
            return .status(jobID: positionals[0])
        case "tail":
            let (positionals, values) = try options(rest, allowed: ["--stream", "--lines"])
            guard positionals.count == 1 else { throw usageError("tail takes exactly one remote_job_id.") }
            var lines = 120
            if let raw = values["--lines"] {
                guard let value = Int(raw), value > 0 else { throw usageError("--lines must be a positive number.") }
                lines = min(value, RemoteWorkspaceJobScripts.maximumTailLines)
            }
            return .tail(jobID: positionals[0], stream: values["--stream"] ?? "stdout", lines: lines)
        case "help", "--help", "-h":
            return .help
        case "wait":
            throw usageError("There is no wait: a remote job runs without this turn. End your turn and check it with `\(commandName) status <remote_job_id>` in a later one.")
        default:
            throw usageError("Unknown subcommand `\(subcommand)`.")
        }
    }

    /// Everything after `--` is the remote command, joined with spaces the
    /// way `ssh` joins its trailing arguments.
    private static func parseStart(_ arguments: [String]) throws -> Command {
        guard let separator = arguments.firstIndex(of: "--") else {
            throw usageError("start needs `--` before the remote command, as in `\(commandName) start --connection <target> -- '<command>'`.")
        }
        let (positionals, values) = try options(Array(arguments[..<separator]), allowed: ["--connection", "--label", "--timeout"])
        guard positionals.isEmpty else {
            throw usageError("Unexpected argument `\(positionals[0])` before `--`.")
        }
        let remoteCommand = arguments[arguments.index(after: separator)...].joined(separator: " ")
        var timeout: Int?
        if let raw = values["--timeout"] {
            guard let value = Int(raw) else { throw usageError("--timeout must be a whole number of seconds.") }
            timeout = value
        }
        try RemoteWorkspaceJobManager.validate(command: remoteCommand, label: values["--label"], timeoutSeconds: timeout)
        return .start(connection: values["--connection"], label: values["--label"], timeoutSeconds: timeout, command: remoteCommand)
    }

    private static func options(_ arguments: [String], allowed: Set<String>) throws -> ([String], [String: String]) {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }
            let name: String
            let value: String
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                value = String(argument[argument.index(after: equals)...])
                index += 1
            } else {
                name = argument
                guard index + 1 < arguments.endIndex else { throw usageError("\(name) needs a value.") }
                value = arguments[index + 1]
                index += 2
            }
            guard allowed.contains(name) else { throw usageError("Unknown option \(name).") }
            values[name] = value
        }
        return (positionals, values)
    }

    private static func usageError(_ message: String) -> RemoteWorkspaceJobError {
        .invalidArgument(message)
    }

    public static let usage = """
    Usage:
      \(commandName) start [--connection <target>] [--label <text>] [--timeout <seconds>] -- '<command>'
      \(commandName) status <remote_job_id>
      \(commandName) tail <remote_job_id> [--stream stdout|stderr] [--lines N]

    start runs <command> detached on the SSH host, the way `ssh <target> '<command>'` would run it, and returns at once.
    <target> is what follows `ssh` for the connection; it can be left out when the run offers one.
    """

    // MARK: - Output

    static func output(_ outcome: RemoteWorkspaceJobOutcome, store: RemoteWorkspaceJobStore) -> Output {
        switch outcome {
        case .record(let record):
            return Output(exitCode: 0, stdout: formatted(record, store: store) + "\n", stderr: "")
        case .failure(let message, let record):
            return Output(
                exitCode: 1,
                stdout: record.map { formatted($0, store: store) + "\n" } ?? "",
                stderr: message + "\n"
            )
        }
    }

    public static func formatted(_ record: RemoteWorkspaceJobRecord, store: RemoteWorkspaceJobStore) -> String {
        var lines = [
            "remote_job_id: \(record.jobID)",
            "status: \(record.status.rawValue)",
            "runtime: ssh",
            "connection: \(record.connectionTarget)",
            "command: \(record.command.replacingOccurrences(of: "\n", with: "\\n"))"
        ]
        if let label = record.label { lines.append("label: \(label)") }
        if let launch = record.launch {
            lines.append("remote_pid: \(launch.pid)")
            lines.append("isolation: \(launch.isolation)")
        }
        lines.append("remote_dir: ~/\(record.remoteDirectory)")
        if let startedAt = record.launch?.startedAt { lines.append("started_at: \(iso(startedAt))") }
        if let exitCode = record.exitCode { lines.append("exit_code: \(exitCode)") }
        if let completedAt = record.completedAt { lines.append("completed_at: \(iso(completedAt))") }
        if let verified = record.lastVerifiedAt { lines.append("last_verified_at: \(iso(verified))") }
        if let observation = record.lastObservation {
            lines.append("observation: \(observation.outcome.rawValue) at \(iso(observation.at))")
            if let error = observation.error { lines.append("observation_error: \(error)") }
        }
        if let bytes = record.stdoutBytes { lines.append("stdout_bytes: \(bytes)") }
        if let bytes = record.stderrBytes { lines.append("stderr_bytes: \(bytes)") }
        if let lastOutputAt = record.lastOutputAt { lines.append("last_output_at: \(iso(lastOutputAt))") }
        if let message = record.message { lines.append("message: \(message)") }
        if let url = try? store.recordURL(jobID: record.jobID) { lines.append("record: \(url.path)") }
        lines.append("next: \(nextStep(for: record))")
        return lines.joined(separator: "\n")
    }

    static func nextStep(for record: RemoteWorkspaceJobRecord) -> String {
        let status = "`\(commandName) status \(record.jobID)`"
        if record.lastObservation?.outcome == .unreachable, !record.status.isTerminal {
            return "ASTRA could not reach the host, so the status above is the last one it verified. Do not start the job again; check it with \(status) later."
        }
        switch record.status {
        case .starting:
            return "The host has not confirmed the launch yet. Run \(status) once before starting it again."
        case .running:
            return "The job runs on the host without this turn. End your turn now and tell the user the remote_job_id; a later turn checks it with one \(status) call, never a polling loop."
        case .succeeded, .failed, .timedOut:
            return "Read its output with `\(commandName) tail \(record.jobID)` (add `--stream stderr` for errors)."
        case .lost:
            return "The job ended without an exit code. Read `\(commandName) tail \(record.jobID)` and tell the user before starting it again."
        }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
