import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A detached job on an SSH workspace's host, as ASTRA last verified it.
///
/// The host owns whether the job is alive and how it ended (its fixed job
/// directory under `$HOME/.astra/jobs`); the task folder's record owns which
/// jobs exist and what ASTRA last saw. See
/// docs/specs/2026-10-21-ssh-remote-managed-jobs.md.
public enum RemoteWorkspaceJobStatus: String, Codable, Equatable, Sendable {
    /// Recorded before the launch was confirmed by the host's evidence.
    case starting
    case running
    case succeeded
    case failed
    case timedOut = "timed_out"
    case cancelled
    case unverified
    /// Ended without recording an exit code: the host rebooted, the job and its
    /// supervisor were killed, the launch never ran, or its directory is gone.
    case lost

    public var isTerminal: Bool {
        switch self {
        case .starting, .running, .lost, .unverified:
            return false
        case .succeeded, .failed, .timedOut, .cancelled:
            return true
        }
    }
}

/// One SSH connection the run may start jobs on. `target` is exactly what
/// follows `ssh` in the run line; `arguments` is the same thing as argv.
public struct RemoteWorkspaceJobConnection: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var target: String
    public var arguments: [String]

    public init(id: String, name: String, target: String, arguments: [String]) {
        self.id = id
        self.name = name
        self.target = target
        self.arguments = arguments
    }
}

/// What the launcher wrote on the host once the command was running. The boot
/// id and start markers make a reused PID or a rebooted host detectable.
public struct RemoteWorkspaceJobLaunchEvidence: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startMarker: String?
    public var supervisorPID: Int32?
    public var supervisorStartMarker: String?
    public var bootID: String
    public var startedAt: Date?
    /// `setsid` when the command got its own session and process group,
    /// `nohup` where the host has no `setsid`.
    public var isolation: String
    public var shell: String?

    public init(
        pid: Int32,
        startMarker: String? = nil,
        supervisorPID: Int32? = nil,
        supervisorStartMarker: String? = nil,
        bootID: String,
        startedAt: Date? = nil,
        isolation: String,
        shell: String? = nil
    ) {
        self.pid = pid
        self.startMarker = startMarker
        self.supervisorPID = supervisorPID
        self.supervisorStartMarker = supervisorStartMarker
        self.bootID = bootID
        self.startedAt = startedAt
        self.isolation = isolation
        self.shell = shell
    }
}

public struct RemoteWorkspaceJobObservation: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case reachable
        case unreachable
    }

    public var at: Date
    public var outcome: Outcome
    public var error: String?

    public init(at: Date, outcome: Outcome, error: String? = nil) {
        self.at = at
        self.outcome = outcome
        self.error = error
    }
}

public struct RemoteWorkspaceJobRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var jobID: String
    public var taskID: String?
    public var runID: String?
    /// Display only. Anything that later reaches the host again resolves the
    /// connection from the workspace by `connectionID`; the record sits in an
    /// agent-writable folder and is never a source of `ssh` arguments.
    public var connectionID: String
    public var connectionName: String
    public var connectionTarget: String
    public var command: String
    public var label: String?
    public var timeoutSeconds: Int?
    public var createdAt: Date
    public var launch: RemoteWorkspaceJobLaunchEvidence?
    public var status: RemoteWorkspaceJobStatus
    public var exitCode: Int32?
    public var completedAt: Date?
    public var lastVerifiedAt: Date?
    public var lastObservation: RemoteWorkspaceJobObservation?
    public var stdoutBytes: Int64?
    public var stderrBytes: Int64?
    public var lastOutputAt: Date?
    public var message: String?
    public var launchIntentKey: String?
    public var launchNonce: String?
    public var ownerID: String?
    public var executionID: String?
    public var connectionArguments: [String]?
    public var cancellationRequestedAt: Date?
    public var remoteClock: RemoteWorkspaceJobClock.Reference?
    public var pendingTransitions: [RemoteWorkspaceJobTransition]?

    /// POSIX process groups cannot contain tools which detach or start work on
    /// another host. Observations never grant the execution owner's stop proof.
    public var cleanupVerified: Bool { false }

    public init(
        jobID: String,
        taskID: String? = nil,
        runID: String? = nil,
        connection: RemoteWorkspaceJobConnection,
        command: String,
        label: String? = nil,
        timeoutSeconds: Int? = nil,
        createdAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.jobID = jobID
        self.taskID = taskID
        self.runID = runID
        self.connectionID = connection.id
        self.connectionName = connection.name
        self.connectionTarget = connection.target
        self.command = command
        self.label = label
        self.timeoutSeconds = timeoutSeconds
        self.createdAt = createdAt
        self.status = .starting
        self.launchNonce = UUID().uuidString.lowercased()
        self.connectionArguments = connection.arguments
    }

    /// The remote job directory, relative to the host user's home.
    public var remoteDirectory: String {
        RemoteWorkspaceJobScripts.remoteDirectory(jobID: jobID)
    }

    /// The only way a record's state changes. Monotonic: an observation older
    /// than the last one is dropped. A later complete probe may correct an
    /// earlier result; neither observation is authority to release resources.
    public mutating func apply(_ result: RemoteWorkspaceJobObservationResult) {
        if let last = lastObservation, last.at > result.at { return }
        switch result {
        case .unreachable(let at, let error):
            lastObservation = RemoteWorkspaceJobObservation(at: at, outcome: .unreachable, error: error)
        case .reachable(let at, let snapshot, let derived):
            lastObservation = RemoteWorkspaceJobObservation(at: at, outcome: .reachable)
            lastVerifiedAt = at
            if launch == nil { launch = snapshot.evidence }
            if let bytes = snapshot.stdoutBytes { stdoutBytes = bytes }
            if let bytes = snapshot.stderrBytes { stderrBytes = bytes }
            if let latest = [snapshot.stdoutModifiedAt, snapshot.stderrModifiedAt].compactMap({ $0 }).max() {
                lastOutputAt = latest
            }
            status = derived.status
            exitCode = derived.exitCode
            completedAt = derived.completedAt ?? (derived.status.isTerminal ? at : nil)
            message = derived.message
        }
    }

    /// A launch the host refused before anything ran.
    public mutating func markLaunchRefused(at: Date, message: String) {
        guard !status.isTerminal else { return }
        status = .failed
        completedAt = at
        self.message = message
        lastObservation = RemoteWorkspaceJobObservation(at: at, outcome: .reachable)
        lastVerifiedAt = at
    }
}

public enum RemoteWorkspaceJobObservationResult: Equatable, Sendable {
    case reachable(at: Date, snapshot: RemoteWorkspaceJobHostSnapshot, derived: RemoteWorkspaceJobDerivedState)
    case unreachable(at: Date, error: String)

    var at: Date {
        switch self {
        case .reachable(let at, _, _), .unreachable(let at, _):
            return at
        }
    }
}

public struct RemoteWorkspaceJobDerivedState: Equatable, Sendable {
    public var status: RemoteWorkspaceJobStatus
    public var exitCode: Int32?
    public var completedAt: Date?
    public var message: String?

    public init(status: RemoteWorkspaceJobStatus, exitCode: Int32? = nil, completedAt: Date? = nil, message: String? = nil) {
        self.status = status
        self.exitCode = exitCode
        self.completedAt = completedAt
        self.message = message
    }
}

/// What one probe printed about a job, parsed from its `key=value` lines.
public struct RemoteWorkspaceJobHostSnapshot: Equatable, Sendable {
    public var jobID: String? = nil
    public var nonce: String? = nil
    public var directoryPresent: Bool
    public var hostBootID: String?
    public var evidence: RemoteWorkspaceJobLaunchEvidence?
    public var pidAlive: Bool
    public var pidStartMarker: String?
    public var supervisorAlive: Bool
    public var supervisorStartMarker: String?
    public var resultStatus: String?
    public var resultExitCode: Int32?
    public var resultCompletedAt: Date?
    public var stdoutBytes: Int64?
    public var stderrBytes: Int64?
    public var stdoutModifiedAt: Date?
    public var stderrModifiedAt: Date?

    /// `nil` when the output carries no probe marker: a login banner or a
    /// failed script is not evidence about the job.
    public static func parse(_ output: String) -> RemoteWorkspaceJobHostSnapshot? {
        var fields: [String: String] = [:]
        var sawMarker = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line == "\(RemoteWorkspaceJobScripts.probeMarker)=2" {
                sawMarker = true
                fields = [:]
                continue
            }
            guard sawMarker, let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil else { return nil }
            fields[key] = value
        }
        guard sawMarker, let jobID = fields["job_id"], let nonce = fields["nonce"],
              UUID(uuidString: jobID) != nil, UUID(uuidString: nonce) != nil,
              fields["astra_probe_end"] == "\(jobID):\(nonce)",
              output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("astra_probe_end=\(jobID):\(nonce)"),
              nonEmpty(fields["host_boot_id"]) != nil,
              ["present", "missing"].contains(fields["state"] ?? ""),
              ["0", "1"].contains(fields["pid_alive"] ?? ""),
              ["0", "1"].contains(fields["supervisor_alive"] ?? "") else { return nil }

        var snapshot = RemoteWorkspaceJobHostSnapshot(
            jobID: jobID, nonce: nonce,
            directoryPresent: fields["state"] == "present",
            hostBootID: nonEmpty(fields["host_boot_id"]),
            evidence: nil,
            pidAlive: fields["pid_alive"] == "1",
            pidStartMarker: nonEmpty(fields["pid_start_marker"]),
            supervisorAlive: fields["supervisor_alive"] == "1",
            supervisorStartMarker: nonEmpty(fields["supervisor_start_marker"]),
            stdoutBytes: fields["stdout_bytes"].flatMap { Int64($0) },
            stderrBytes: fields["stderr_bytes"].flatMap { Int64($0) },
            stdoutModifiedAt: fields["stdout_mtime"].flatMap(epochDate),
            stderrModifiedAt: fields["stderr_mtime"].flatMap(epochDate)
        )
        if let pid = fields["evidence.pid"].flatMap({ Int32($0) }), pid > 1 {
            snapshot.evidence = RemoteWorkspaceJobLaunchEvidence(
                pid: pid,
                startMarker: nonEmpty(fields["evidence.start_marker"]),
                supervisorPID: fields["evidence.supervisor_pid"].flatMap { Int32($0) },
                supervisorStartMarker: nonEmpty(fields["evidence.supervisor_start_marker"]),
                bootID: fields["evidence.boot_id"] ?? "",
                startedAt: fields["evidence.started_at"].flatMap(isoDate),
                isolation: nonEmpty(fields["evidence.isolation"]) ?? "unknown",
                shell: nonEmpty(fields["evidence.shell"])
            )
        }
        if let resultJSON = fields["result"],
           let data = resultJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard object["job_id"] as? String == jobID, object["nonce"] as? String == nonce,
                  let status = object["status"] as? String,
                  ["succeeded", "failed", "timed_out", "cancelled"].contains(status),
                  let code = object["exit_code"] as? NSNumber,
                  String(cString: code.objCType) != "c", code.doubleValue.isFinite,
                  code.doubleValue == Double(code.int32Value),
                  let completed = (object["completed_at"] as? String).flatMap(isoDate) else { return nil }
            snapshot.resultStatus = status
            snapshot.resultExitCode = code.int32Value
            snapshot.resultCompletedAt = completed
        } else if fields["result"] != nil {
            return nil
        }
        return snapshot
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func epochDate(_ value: String) -> Date? {
        TimeInterval(value).map { Date(timeIntervalSince1970: $0) }
    }

    static func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

/// The status table from the spec, in one place.
public enum RemoteWorkspaceJobStatusDerivation {
    /// When a missing launch becomes visibly unverified, never restartable.
    public static let launchGraceSeconds: TimeInterval = 60

    public static func derive(
        snapshot: RemoteWorkspaceJobHostSnapshot,
        record: RemoteWorkspaceJobRecord,
        now: Date
    ) -> RemoteWorkspaceJobDerivedState {
        let withinLaunchGrace = now.timeIntervalSince(record.createdAt) < launchGraceSeconds
        guard snapshot.directoryPresent else {
            guard record.launch == nil else {
                return unverified("The job directory is missing. Earlier work may still be running; its reservation is preserved.")
            }
            // A start still in flight has not made its directory yet.
            return withinLaunchGrace
                ? RemoteWorkspaceJobDerivedState(status: .starting, message: "The host has not confirmed the launch yet.")
                : unverified("The launch is not confirmed. A delayed launch remains possible; ASTRA will inspect the same job again.")
        }
        if let evidence = record.launch ?? snapshot.evidence,
           snapshot.hostBootID != evidence.bootID {
            return unverified("The host identity changed or rebooted. Remote tool cleanup is not confirmed.")
        }
        if let status = snapshot.resultStatus {
            let mapped: RemoteWorkspaceJobStatus
            switch status {
            case "succeeded": mapped = .succeeded
            case "timed_out": mapped = .timedOut
            case "cancelled": mapped = .cancelled
            default: mapped = .failed
            }
            return RemoteWorkspaceJobDerivedState(
                status: mapped,
                exitCode: snapshot.resultExitCode,
                completedAt: snapshot.resultCompletedAt ?? now,
                message: mapped == .timedOut ? "ASTRA stopped the job at its \(record.timeoutSeconds ?? 0)-second timeout." : nil
            )
        }
        guard let evidence = record.launch ?? snapshot.evidence else {
            if withinLaunchGrace {
                return RemoteWorkspaceJobDerivedState(status: .starting, message: "The host has not confirmed the launch yet.")
            }
            return unverified("The launcher has not confirmed the command starting. Do not launch another attempt.")
        }
        if let hostBootID = snapshot.hostBootID, !evidence.bootID.isEmpty, hostBootID != evidence.bootID {
            return unverified("The host rebooted after the job started. Tool cleanup remains unverified.")
        }
        if snapshot.pidAlive, markersMatch(evidence.startMarker, snapshot.pidStartMarker) {
            return RemoteWorkspaceJobDerivedState(status: .running)
        }
        if snapshot.supervisorAlive, markersMatch(evidence.supervisorStartMarker, snapshot.supervisorStartMarker) {
            // The command is gone; its supervisor is writing the result.
            return RemoteWorkspaceJobDerivedState(status: .running)
        }
        return unverified("The managed processes are not observed and no exit code was recorded. Detached tools may still be running.")
    }

    /// A missing or different identity is never evidence of this execution.
    static func markersMatch(_ recorded: String?, _ current: String?) -> Bool {
        guard let recorded = normalized(recorded) else { return false }
        return recorded == normalized(current)
    }

    private static func normalized(_ marker: String?) -> String? {
        let words = (marker ?? "").split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func unverified(_ message: String) -> RemoteWorkspaceJobDerivedState {
        RemoteWorkspaceJobDerivedState(status: .unverified, message: message)
    }
}
