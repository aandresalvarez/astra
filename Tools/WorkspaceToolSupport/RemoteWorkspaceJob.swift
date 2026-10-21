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
    /// Ended without recording an exit code: the host rebooted, the job and its
    /// supervisor were killed, the launch never ran, or its directory is gone.
    case lost

    public var isTerminal: Bool {
        switch self {
        case .starting, .running:
            return false
        case .succeeded, .failed, .timedOut, .lost:
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
    public static let currentSchemaVersion = 1

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
    }

    /// The remote job directory, relative to the host user's home.
    public var remoteDirectory: String {
        RemoteWorkspaceJobScripts.remoteDirectory(jobID: jobID)
    }

    /// The only way a record's state changes. Monotonic: an observation older
    /// than the last one is dropped, and a terminal status is never replaced,
    /// so the helper and a later watcher can both write without either one
    /// undoing the other.
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
            guard !status.isTerminal else { return }
            status = derived.status
            exitCode = derived.exitCode ?? exitCode
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
            if line == "\(RemoteWorkspaceJobScripts.probeMarker)=1" {
                sawMarker = true
                fields = [:]
                continue
            }
            guard sawMarker, let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard sawMarker else { return nil }

        var snapshot = RemoteWorkspaceJobHostSnapshot(
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
            snapshot.resultStatus = object["status"] as? String
            snapshot.resultExitCode = (object["exit_code"] as? NSNumber)?.int32Value
            snapshot.resultCompletedAt = (object["completed_at"] as? String).flatMap(isoDate)
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
    /// How long a job may have no launch evidence before it counts as lost.
    public static let launchGraceSeconds: TimeInterval = 60

    public static func derive(
        snapshot: RemoteWorkspaceJobHostSnapshot,
        record: RemoteWorkspaceJobRecord,
        now: Date
    ) -> RemoteWorkspaceJobDerivedState {
        let withinLaunchGrace = now.timeIntervalSince(record.createdAt) < launchGraceSeconds
        guard snapshot.directoryPresent else {
            guard record.launch == nil else {
                return lost("The job's directory (~/\(record.remoteDirectory)) is not on the host: it was deleted, or a different host answered.")
            }
            // A start still in flight has not made its directory yet.
            return withinLaunchGrace
                ? RemoteWorkspaceJobDerivedState(status: .starting, message: "The host has not confirmed the launch yet.")
                : lost("The launch never reached the host: its job directory was never created.")
        }
        if let status = snapshot.resultStatus {
            let mapped: RemoteWorkspaceJobStatus
            switch status {
            case "succeeded": mapped = .succeeded
            case "timed_out": mapped = .timedOut
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
            return lost("The launcher never recorded the command starting.")
        }
        if let hostBootID = snapshot.hostBootID, !evidence.bootID.isEmpty, hostBootID != evidence.bootID {
            return lost("The host rebooted after the job started, and the job recorded no exit code.")
        }
        if snapshot.pidAlive, markersMatch(evidence.startMarker, snapshot.pidStartMarker) {
            return RemoteWorkspaceJobDerivedState(status: .running)
        }
        if snapshot.supervisorAlive, markersMatch(evidence.supervisorStartMarker, snapshot.supervisorStartMarker) {
            // The command is gone; its supervisor is writing the result.
            return RemoteWorkspaceJobDerivedState(status: .running)
        }
        return lost("The job and its supervisor are gone and no exit code was recorded (killed, out of memory, or cleaned up on the host).")
    }

    /// A marker the launcher could not read (empty) is not a mismatch; a
    /// different one means the PID now belongs to another process.
    static func markersMatch(_ recorded: String?, _ current: String?) -> Bool {
        guard let recorded = normalized(recorded) else { return true }
        return recorded == normalized(current)
    }

    private static func normalized(_ marker: String?) -> String? {
        let words = (marker ?? "").split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func lost(_ message: String) -> RemoteWorkspaceJobDerivedState {
        RemoteWorkspaceJobDerivedState(status: .lost, message: message)
    }
}

public enum RemoteWorkspaceJobStoreError: LocalizedError, Equatable, Sendable {
    case invalidJobID(String)
    case notFound(String)
    case alreadyExists(String)
    case unsafePath(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJobID(let value):
            return "Invalid remote job id: \(value). Use the remote_job_id that `astra-workspace-job start` printed."
        case .notFound(let jobID):
            return "No remote job \(jobID) is recorded for this task."
        case .alreadyExists(let jobID):
            return "Remote job \(jobID) is already recorded."
        case .unsafePath(let path):
            return "The remote job record path is not a plain file or directory: \(path)"
        case .unreadable(let path):
            return "The remote job record could not be read: \(path)"
        }
    }
}

/// `<task folder>/remote-jobs/<job_id>.json`, one JSON file per job, each
/// change made under an exclusive lock and written by atomic replace.
public final class RemoteWorkspaceJobStore {
    public let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootPath: String, fileManager: FileManager = .default) {
        self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        // Fractional seconds, so a record read back equals the one written and
        // "is this observation older than the last" is not decided by rounding.
        self.encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.fractionalFormatter().string(from: date))
        }
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.fractionalFormatter().date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
    }

    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// A lowercase UUID, the only shape a job id ever has. Everything that
    /// becomes a path, local or remote, goes through this first.
    public static func canonicalJobID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed), uuid.uuidString.lowercased() == trimmed.lowercased() else {
            throw RemoteWorkspaceJobStoreError.invalidJobID(trimmed)
        }
        return uuid.uuidString.lowercased()
    }

    public func recordURL(jobID: String) throws -> URL {
        rootURL.appendingPathComponent("\(try Self.canonicalJobID(jobID)).json", isDirectory: false)
    }

    public func create(_ record: RemoteWorkspaceJobRecord) throws {
        let url = try recordURL(jobID: record.jobID)
        try withLock(jobID: record.jobID) {
            guard try existingRegularFile(at: url) == false else {
                throw RemoteWorkspaceJobStoreError.alreadyExists(record.jobID)
            }
            try write(record, to: url)
        }
    }

    public func load(jobID: String) throws -> RemoteWorkspaceJobRecord {
        let url = try recordURL(jobID: jobID)
        return try withLock(jobID: jobID) { try read(at: url, jobID: jobID) }
    }

    @discardableResult
    public func update(
        jobID: String,
        _ body: (inout RemoteWorkspaceJobRecord) throws -> Void
    ) throws -> RemoteWorkspaceJobRecord {
        let url = try recordURL(jobID: jobID)
        return try withLock(jobID: jobID) {
            var record = try read(at: url, jobID: jobID)
            try body(&record)
            try write(record, to: url)
            return try read(at: url, jobID: jobID)
        }
    }

    private func read(at url: URL, jobID: String) throws -> RemoteWorkspaceJobRecord {
        guard try existingRegularFile(at: url) else {
            throw RemoteWorkspaceJobStoreError.notFound(try Self.canonicalJobID(jobID))
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteWorkspaceJobStoreError.unreadable(url.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let record = try? decoder.decode(RemoteWorkspaceJobRecord.self, from: data),
              (try? Self.canonicalJobID(record.jobID)) == (try Self.canonicalJobID(jobID)) else {
            throw RemoteWorkspaceJobStoreError.unreadable(url.path)
        }
        return record
    }

    private func write(_ record: RemoteWorkspaceJobRecord, to url: URL) throws {
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `true` for a regular file, `false` when nothing is there, and a throw
    /// for anything else (a symlink, a directory), so a planted link is never
    /// followed or replaced.
    private func existingRegularFile(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw RemoteWorkspaceJobStoreError.unreadable(url.path) }
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw RemoteWorkspaceJobStoreError.unsafePath(url.path)
        }
        return true
    }

    private func prepareRoot() throws {
        var info = stat()
        if lstat(rootURL.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw RemoteWorkspaceJobStoreError.unsafePath(rootURL.path)
            }
            return
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func withLock<T>(jobID: String, _ body: () throws -> T) throws -> T {
        try prepareRoot()
        let lockPath = rootURL.appendingPathComponent(".\(try Self.canonicalJobID(jobID)).lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteWorkspaceJobStoreError.unsafePath(lockPath) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw RemoteWorkspaceJobStoreError.unreadable(lockPath) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
