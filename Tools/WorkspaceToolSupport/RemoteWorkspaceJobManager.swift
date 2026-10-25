import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RemoteWorkspaceJobTransportResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// `ssh` reports its own failures (cannot resolve, refused, dropped
    /// tunnel) as 255; a script ASTRA sent never exits 255.
    public var isTransportFailure: Bool {
        timedOut || exitCode == 255
    }
}

public protocol RemoteWorkspaceJobTransport {
    func run(
        connection: RemoteWorkspaceJobConnection,
        script: String,
        timeoutSeconds: TimeInterval
    ) -> RemoteWorkspaceJobTransportResult
}

/// `ssh <destination arguments> sh -s` with the script on stdin, through the
/// task's SSH wrapper, never prompting.
public struct SSHRemoteWorkspaceJobTransport: RemoteWorkspaceJobTransport {
    public static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=20",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3"
    ]
    static let maximumOutputBytes = 1024 * 1024

    public var sshExecutable: String
    public var additionalOptions: [String]

    public init(sshExecutable: String, additionalOptions: [String] = []) {
        self.sshExecutable = sshExecutable
        self.additionalOptions = additionalOptions
    }

    public static func arguments(for connection: RemoteWorkspaceJobConnection) -> [String] {
        sshOptions + connection.arguments + ["sh", "-s"]
    }

    public func run(
        connection: RemoteWorkspaceJobConnection,
        script: String,
        timeoutSeconds: TimeInterval
    ) -> RemoteWorkspaceJobTransportResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutable)
        process.arguments = additionalOptions + Self.arguments(for: connection)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutBuffer = BoundedBuffer(limit: Self.maximumOutputBytes)
        let stderrBuffer = BoundedBuffer(limit: Self.maximumOutputBytes)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return RemoteWorkspaceJobTransportResult(exitCode: 255, stdout: "", stderr: error.localizedDescription)
        }
        let stdoutDrained = Self.drain(stdout.fileHandleForReading, into: stdoutBuffer)
        let stderrDrained = Self.drain(stderr.fileHandleForReading, into: stderrBuffer)
        // Off this thread, so a host that never reads its stdin cannot hold
        // the call past its timeout. A session that closes early makes the
        // write fail with EPIPE instead of raising SIGPIPE.
        let writer = stdin.fileHandleForWriting
#if canImport(Darwin)
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
#endif
        let payload = Data(script.utf8)
        Thread {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }.start()

        var timedOut = false
        if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // A ProxyCommand (an IAP tunnel) can outlive ssh holding stderr open,
        // so the drain is bounded rather than read to EOF.
        _ = stdoutDrained.wait(timeout: .now() + 2)
        _ = stderrDrained.wait(timeout: .now() + 2)
        return RemoteWorkspaceJobTransportResult(
            exitCode: timedOut ? 255 : process.terminationStatus,
            stdout: stdoutBuffer.string,
            stderr: stderrBuffer.string,
            timedOut: timedOut
        )
    }

    /// Reads chunks as they arrive, so whatever came before a stuck pipe is
    /// kept; signals at EOF.
    private static func drain(_ handle: FileHandle, into buffer: BoundedBuffer) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            done.signal()
        }.start()
        return done
    }
}

private final class BoundedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let room = limit - data.count
        if room > 0 { data.append(chunk.prefix(room)) }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct RemoteWorkspaceJobConfiguration: Codable, Equatable, Sendable {
    public var recordRootPath: String
    public var sshExecutable: String
    public var connections: [RemoteWorkspaceJobConnection]
    public var taskID: String?
    public var runID: String?
    public var ownerBinding: RemoteWorkspaceJobOwnerBinding?
    public var maximumJobSeconds: Int?
    public var launchDeadline: Date?
    public var launchMonotonicDeadline: TimeInterval?
    public var observationSSHOptions: [String]?

    public static let recordRootKey = "ASTRA_REMOTE_JOB_ROOT"
    public static let sshExecutableKey = "ASTRA_REMOTE_JOB_SSH"
    public static let connectionsKey = "ASTRA_REMOTE_JOB_CONNECTIONS"
    public static let taskIDKey = "ASTRA_REMOTE_JOB_TASK_ID"
    public static let runIDKey = "ASTRA_REMOTE_JOB_RUN_ID"
    public static let ownerKey = "ASTRA_REMOTE_JOB_OWNER"
    public static let maximumSecondsKey = "ASTRA_REMOTE_JOB_MAX_SECONDS"

    public init(
        recordRootPath: String,
        sshExecutable: String,
        connections: [RemoteWorkspaceJobConnection],
        taskID: String? = nil,
        runID: String? = nil,
        ownerBinding: RemoteWorkspaceJobOwnerBinding? = nil,
        maximumJobSeconds: Int? = nil
    ) {
        self.recordRootPath = recordRootPath
        self.sshExecutable = sshExecutable
        self.connections = connections
        self.taskID = taskID
        self.runID = runID
        self.ownerBinding = ownerBinding
        self.maximumJobSeconds = maximumJobSeconds
    }

    /// The shim ASTRA writes for a native-shell SSH run exports these. Without
    /// them this run was not offered remote jobs, and nothing is guessed.
    public static func fromEnvironment(_ environment: [String: String]) throws -> RemoteWorkspaceJobConfiguration {
        func value(_ key: String) -> String? {
            let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let root = value(recordRootKey), let ssh = value(sshExecutableKey),
              let connectionsJSON = value(connectionsKey) else {
            throw RemoteWorkspaceJobError.notOffered
        }
        guard let connections = try? JSONDecoder().decode([RemoteWorkspaceJobConnection].self, from: Data(connectionsJSON.utf8)),
              !connections.isEmpty, let ownerJSON = value(ownerKey),
              let owner = try? JSONDecoder().decode(RemoteWorkspaceJobOwnerBinding.self, from: Data(ownerJSON.utf8)),
              let maximum = value(maximumSecondsKey).flatMap(Int.init), maximum > 0,
              owner.taskID == value(taskIDKey), owner.runID == value(runIDKey) else {
            throw RemoteWorkspaceJobError.notOffered
        }
        return RemoteWorkspaceJobConfiguration(
            recordRootPath: root,
            sshExecutable: ssh,
            connections: connections,
            taskID: value(taskIDKey),
            runID: value(runIDKey), ownerBinding: owner, maximumJobSeconds: maximum
        )
    }

    public static func connectionsJSON(_ connections: [RemoteWorkspaceJobConnection]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(connections) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum RemoteWorkspaceJobError: LocalizedError, Equatable, Sendable {
    case notOffered
    case unknownConnection(requested: String?, offered: [String])
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .notOffered:
            return "Remote jobs are not offered to this run: ASTRA only provides astra-workspace-job when the run's SSH route is the native shell. Use the route the \"SSH route for this run\" line describes."
        case .unknownConnection(let requested, let offered):
            let list = offered.map { "`\($0)`" }.joined(separator: ", ")
            guard let requested else {
                return "This run offers more than one SSH connection; pass --connection with one of: \(list)."
            }
            return "`\(requested)` is not an SSH connection this run offers. Use one of: \(list)."
        case .invalidArgument(let message):
            return message
        }
    }
}

public enum RemoteWorkspaceJobOutcome: Equatable, Sendable {
    /// The request was carried out; the record says what ASTRA verified.
    case record(RemoteWorkspaceJobRecord)
    /// The request was not carried out. A record is attached when one exists
    /// (a launch ASTRA could not confirm), so its id is never lost.
    case failure(message: String, record: RemoteWorkspaceJobRecord?)
}

public enum RemoteWorkspaceJobTailOutcome: Equatable, Sendable {
    case text(jobID: String, stream: String, text: String)
    case failure(message: String)
}

public final class RemoteWorkspaceJobManager {
    public static let maximumTimeoutSeconds = 30 * 24 * 3600
    static let startTransportTimeout: TimeInterval = 90
    static let probeTransportTimeout: TimeInterval = 60

    public let configuration: RemoteWorkspaceJobConfiguration
    public let store: RemoteWorkspaceJobStore
    private let transport: RemoteWorkspaceJobTransport
    private let now: () -> Date
    private let makeJobID: () -> String

    public init(
        configuration: RemoteWorkspaceJobConfiguration,
        transport: RemoteWorkspaceJobTransport? = nil,
        now: @escaping () -> Date = Date.init,
        makeJobID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.configuration = configuration
        self.store = RemoteWorkspaceJobStore(rootPath: configuration.recordRootPath)
        self.transport = transport ?? SSHRemoteWorkspaceJobTransport(sshExecutable: configuration.sshExecutable, additionalOptions: configuration.observationSSHOptions ?? [])
        self.now = now
        self.makeJobID = makeJobID
    }

    public func connection(target requested: String?) throws -> RemoteWorkspaceJobConnection {
        let offered = configuration.connections
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            guard offered.count == 1 else {
                throw RemoteWorkspaceJobError.unknownConnection(requested: nil, offered: offered.map(\.target))
            }
            return offered[0]
        }
        guard let match = offered.first(where: { $0.target == requested }) else {
            throw RemoteWorkspaceJobError.unknownConnection(requested: requested, offered: offered.map(\.target))
        }
        return match
    }

    /// App-owned admission. Only the first persisted intent may perform SSH.
    public func register(connectionTarget: String?, command: String, label: String? = nil,
                         timeoutSeconds: Int? = nil) throws -> (record: RemoteWorkspaceJobRecord, created: Bool) {
        guard let connectionTarget, !connectionTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteWorkspaceJobError.invalidArgument("start requires an explicit --connection so the SSH destination is checked by the runtime policy.")
        }
        let connection = try self.connection(target: connectionTarget)
        try Self.validate(command: command, label: label, timeoutSeconds: timeoutSeconds)
        let remaining = configuration.launchDeadline.map { Int($0.timeIntervalSince(now()).rounded(.down)) } ?? configuration.maximumJobSeconds
        if let remaining, remaining <= 0 { throw RemoteWorkspaceJobError.invalidArgument("The original execution time limit has expired. No remote job was started.") }
        var record = RemoteWorkspaceJobRecord(
            jobID: try RemoteWorkspaceJobStore.canonicalJobID(makeJobID()),
            taskID: configuration.taskID,
            runID: configuration.runID,
            connection: connection,
            command: command,
            label: label,
            timeoutSeconds: remaining.map { min(timeoutSeconds ?? $0, $0) } ?? timeoutSeconds,
            createdAt: now()
        )
        record.ownerID = configuration.ownerBinding?.ownerID
        record.executionID = configuration.ownerBinding?.executionID
        let intentParts = [configuration.taskID ?? "", configuration.runID ?? "",
            record.ownerID ?? "", record.executionID ?? "", connection.id,
            RemoteWorkspaceJobConfiguration.connectionsJSON([connection]), command,
            label ?? "", timeoutSeconds.map(String.init) ?? ""]
        record.launchIntentKey = SHA256.hash(data: (try? JSONEncoder().encode(intentParts)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
        return try store.register(record) { admitted in
            try configuration.ownerBinding?.validateLaunch()
            do {
                let sample = try RemoteWorkspaceJobClock.sample(transport, connection: connection)
                let wallRemaining = configuration.launchDeadline?.timeIntervalSince(now()) ?? Double(Self.maximumTimeoutSeconds)
                let steadyRemaining = configuration.launchMonotonicDeadline.map { $0 - ProcessInfo.processInfo.systemUptime } ?? wallRemaining
                let allowance = min(Double(timeoutSeconds ?? Self.maximumTimeoutSeconds), wallRemaining, steadyRemaining)
                guard allowance > 0 else { throw RemoteWorkspaceJobError.invalidArgument("The original execution time limit expired during SSH connection. No command was launched.") }
                try configuration.ownerBinding?.validateLaunch()
                admitted.remoteClock = .init(bootID: sample.bootID, deadline: sample.monotonic + allowance)
            } catch {
                admitted.message = error.localizedDescription
                admitted.lastObservation = .init(at: now(), outcome: .unreachable, error: error.localizedDescription)
            }
        }
    }

    public func start(
        connectionTarget: String?,
        command: String,
        label: String? = nil,
        timeoutSeconds: Int? = nil
    ) -> RemoteWorkspaceJobOutcome {
        let record: RemoteWorkspaceJobRecord
        do {
            let registration = try register(connectionTarget: connectionTarget, command: command, label: label, timeoutSeconds: timeoutSeconds)
            guard registration.created else { return status(jobID: registration.record.jobID) }
            record = registration.record
            try configuration.ownerBinding?.validateLaunch()
        } catch { return .failure(message: error.localizedDescription, record: nil) }
        let jobID = record.jobID
        let connection: RemoteWorkspaceJobConnection
        do { connection = try self.connection(forRecord: record) }
        catch { return .failure(message: error.localizedDescription, record: record) }

        guard let remoteClock = record.remoteClock else {
            return .failure(message: record.message ?? "Remote clock unavailable; no command was launched.", record: record)
        }
        let script = RemoteWorkspaceJobScripts.start(jobID: jobID, command: command, timeoutSeconds: record.timeoutSeconds,
            nonce: record.launchNonce!, clock: remoteClock)
        let observedAt = now()
        let result = transport.run(connection: connection, script: script, timeoutSeconds: Self.startTransportTimeout)

        if !result.isTransportFailure,
           [RemoteWorkspaceJobScripts.existingJobExitCode, RemoteWorkspaceJobScripts.unwritableRootExitCode].contains(result.exitCode) {
            let reason = Self.scriptError(in: result.stdout) ?? Self.oneLine(result.stderr)
            let updated = try? store.update(jobID: jobID) {
                $0.markLaunchRefused(at: observedAt, message: "The host refused the launch: \(reason)")
            }
            return .failure(message: "The host refused the launch: \(reason)", record: updated)
        }

        let updated: RemoteWorkspaceJobRecord
        do {
            updated = try apply(result, jobID: jobID, at: observedAt)
        } catch {
            return .failure(message: error.localizedDescription, record: record)
        }
        if updated.lastObservation?.outcome == .unreachable {
            let reason = updated.lastObservation?.error ?? "no reply"
            return .failure(
                message: "ASTRA could not confirm the launch on `\(connection.target)` (\(reason)). The job may or may not have started; run `astra-workspace-job status \(jobID)` before starting it again.",
                record: updated
            )
        }
        return .record(updated)
    }

    public func status(jobID rawJobID: String) -> RemoteWorkspaceJobOutcome {
        let record: RemoteWorkspaceJobRecord
        do {
            record = try store.load(jobID: RemoteWorkspaceJobStore.canonicalJobID(rawJobID))
        } catch {
            return .failure(message: error.localizedDescription, record: nil)
        }
        let connection: RemoteWorkspaceJobConnection
        do {
            connection = try self.connection(forRecord: record)
            guard record.launchNonce.flatMap(UUID.init(uuidString:)) != nil else {
                throw RemoteWorkspaceJobError.invalidArgument("Legacy remote job identity is incomplete. Cleanup remains unverified.")
            }
        } catch {
            return .failure(message: error.localizedDescription, record: record)
        }
        let observedAt = now()
        let result = transport.run(
            connection: connection,
            script: record.cancellationRequestedAt == nil
                ? RemoteWorkspaceJobScripts.probe(jobID: record.jobID, nonce: record.launchNonce!)
                : RemoteWorkspaceJobScripts.cancel(jobID: record.jobID, nonce: record.launchNonce!),
            timeoutSeconds: Self.probeTransportTimeout
        )
        do {
            return .record(try apply(result, jobID: record.jobID, at: observedAt))
        } catch {
            return .failure(message: error.localizedDescription, record: record)
        }
    }

    public func cancel(jobID: String) -> RemoteWorkspaceJobOutcome {
        do {
            // Persist intent before contacting SSH; a disconnected host or an
            // ASTRA restart cannot lose a requested cancellation.
            try store.update(jobID: jobID) { if $0.cancellationRequestedAt == nil { $0.cancellationRequestedAt = now() } }
            return status(jobID: jobID)
        } catch { return .failure(message: error.localizedDescription, record: nil) }
    }

    public func tail(jobID rawJobID: String, stream rawStream: String, lines: Int) -> RemoteWorkspaceJobTailOutcome {
        let stream = rawStream.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard stream == "stdout" || stream == "stderr" else {
            return .failure(message: "--stream must be stdout or stderr.")
        }
        let record: RemoteWorkspaceJobRecord
        let connection: RemoteWorkspaceJobConnection
        do {
            record = try store.load(jobID: RemoteWorkspaceJobStore.canonicalJobID(rawJobID))
            connection = try self.connection(forRecord: record)
        } catch {
            return .failure(message: error.localizedDescription)
        }
        let result = transport.run(
            connection: connection,
            script: RemoteWorkspaceJobScripts.tail(jobID: record.jobID, stream: stream, lines: lines, nonce: record.launchNonce ?? "legacy"),
            timeoutSeconds: Self.probeTransportTimeout
        )
        if result.isTransportFailure || result.exitCode != 0 {
            return .failure(message: "ASTRA could not reach `\(connection.target)` to read the log: \(Self.transportError(result)).")
        }
        guard let marker = result.stdout.range(of: "\(RemoteWorkspaceJobScripts.tailMarker)=") else {
            return .failure(message: "The host did not answer the log read (exit \(result.exitCode)): \(Self.oneLine(result.stderr))")
        }
        let afterMarker = result.stdout[marker.upperBound...]
        if afterMarker.hasPrefix("missing") {
            return .failure(message: "The job's directory (~/\(record.remoteDirectory)) is not on the host.")
        }
        let text = afterMarker.drop { $0 != "\n" }.dropFirst()
        return .text(jobID: record.jobID, stream: stream, text: Self.bounded(String(text), lines: lines))
    }

    /// The record's connection, but only while this run still offers it:
    /// the record names the connection, the run's own configuration supplies
    /// the `ssh` arguments.
    private func connection(forRecord record: RemoteWorkspaceJobRecord) throws -> RemoteWorkspaceJobConnection {
        guard let match = configuration.connections.first(where: { $0.id == record.connectionID }),
              match.target == record.connectionTarget, match.arguments == record.connectionArguments,
              record.taskID == configuration.taskID, record.runID == configuration.runID,
              record.ownerID == configuration.ownerBinding?.ownerID,
              record.executionID == configuration.ownerBinding?.executionID else {
            throw RemoteWorkspaceJobError.unknownConnection(
                requested: record.connectionTarget,
                offered: configuration.connections.map(\.target)
            )
        }
        return match
    }

    private func apply(_ result: RemoteWorkspaceJobTransportResult, jobID: String, at observedAt: Date) throws -> RemoteWorkspaceJobRecord {
        try store.update(jobID: jobID) { record in
            guard !result.isTransportFailure, result.exitCode == 0,
                  let snapshot = RemoteWorkspaceJobHostSnapshot.parse(result.stdout),
                  snapshot.jobID == record.jobID, snapshot.nonce == record.launchNonce else {
                let error = result.isTransportFailure
                    ? Self.transportError(result)
                    : "the host's reply had no probe output (exit \(result.exitCode)): \(Self.oneLine(result.stderr))"
                record.apply(.unreachable(at: observedAt, error: error))
                return
            }
            let derived = RemoteWorkspaceJobStatusDerivation.derive(snapshot: snapshot, record: record, now: observedAt)
            record.apply(.reachable(at: observedAt, snapshot: snapshot, derived: derived))
        }
    }

    static func validate(command: String, label: String?, timeoutSeconds: Int?) throws {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteWorkspaceJobError.invalidArgument("start needs a remote command after `--`.")
        }
        guard command.utf8.count <= 65_536 else { throw RemoteWorkspaceJobError.invalidArgument("The remote command exceeds 64 KiB; run a script file instead.") }
        if let label, label.contains(where: \.isNewline) || label.count > 200 {
            throw RemoteWorkspaceJobError.invalidArgument("--label must be one line of at most 200 characters.")
        }
        if let timeoutSeconds, !(1...maximumTimeoutSeconds).contains(timeoutSeconds) {
            throw RemoteWorkspaceJobError.invalidArgument("--timeout must be between 1 and \(maximumTimeoutSeconds) seconds.")
        }
    }

    static func transportError(_ result: RemoteWorkspaceJobTransportResult) -> String {
        if result.timedOut { return "ssh did not answer in time" }
        let detail = oneLine(result.stderr)
        return detail.isEmpty ? "ssh exited \(result.exitCode)" : "ssh exited \(result.exitCode): \(detail)"
    }

    static func scriptError(in output: String) -> String? {
        output.split(separator: "\n").lazy
            .compactMap { line -> String? in
                guard line.hasPrefix("astra_error=") else { return nil }
                return String(line.dropFirst("astra_error=".count))
            }
            .first
    }

    static func oneLine(_ text: String, limit: Int = 300) -> String {
        let joined = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }

    /// The host caps the tail too; this keeps a misbehaving host from
    /// flooding the transcript anyway.
    static func bounded(_ text: String, lines: Int) -> String {
        let count = max(1, min(lines, RemoteWorkspaceJobScripts.maximumTailLines))
        var kept = text.split(separator: "\n", omittingEmptySubsequences: false)
        if kept.last == "" { kept.removeLast() }
        var result = kept.suffix(count).joined(separator: "\n")
        if result.utf8.count > RemoteWorkspaceJobScripts.maximumTailBytes {
            result = String(decoding: Data(result.utf8.suffix(RemoteWorkspaceJobScripts.maximumTailBytes)), as: UTF8.self)
        }
        return result
    }
}
