import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum WorkspaceManagedJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed_out"
}

public struct WorkspaceManagedJobRecord: Codable, Equatable, Sendable {
    public var jobID: String
    public var command: String
    public var label: String?
    public var progressProbe: String?
    public var runtime: String
    public var status: WorkspaceManagedJobStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var updatedAt: Date
    public var completedAt: Date?
    public var lastHeartbeatAt: Date?
    public var lastOutputAt: Date?
    public var timeoutSeconds: TimeInterval?
    public var exitCode: Int32?
    public var stdoutLogPath: String
    public var stderrLogPath: String
    public var heartbeatPath: String
    public var resultPath: String
    public var message: String?

    public init(
        jobID: String,
        command: String,
        label: String? = nil,
        progressProbe: String? = nil,
        runtime: String,
        status: WorkspaceManagedJobStatus,
        createdAt: Date,
        startedAt: Date? = nil,
        updatedAt: Date,
        completedAt: Date? = nil,
        lastHeartbeatAt: Date? = nil,
        lastOutputAt: Date? = nil,
        timeoutSeconds: TimeInterval? = nil,
        exitCode: Int32? = nil,
        stdoutLogPath: String,
        stderrLogPath: String,
        heartbeatPath: String,
        resultPath: String,
        message: String? = nil
    ) {
        self.jobID = jobID
        self.command = command
        self.label = label
        self.progressProbe = progressProbe
        self.runtime = runtime
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastOutputAt = lastOutputAt
        self.timeoutSeconds = timeoutSeconds
        self.exitCode = exitCode
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
        self.heartbeatPath = heartbeatPath
        self.resultPath = resultPath
        self.message = message
    }

    public var isTerminal: Bool {
        switch status {
        case .queued, .running:
            return false
        case .succeeded, .failed, .cancelled, .timedOut:
            return true
        }
    }
}

public struct WorkspaceManagedJobTail: Equatable, Sendable {
    public var jobID: String
    public var stream: String
    public var text: String

    public init(jobID: String, stream: String, text: String) {
        self.jobID = jobID
        self.stream = stream
        self.text = text
    }
}

public protocol WorkspaceJobManaging: AnyObject {
    func start(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?
    ) -> WorkspaceManagedJobRecord
    func status(jobID: String) -> WorkspaceManagedJobRecord
    func tail(jobID: String, stream: String, lines: Int) -> WorkspaceManagedJobTail
    func cancel(jobID: String) -> WorkspaceManagedJobRecord
    func wait(jobID: String, timeoutSeconds: TimeInterval) -> WorkspaceManagedJobRecord
}

public final class WorkspaceManagedJobStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    var afterTrustedRegularFileStatForTesting: ((URL) -> Void)?

    public init(rootPath: String, fileManager: FileManager = .default) {
        self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func makeJobID() -> String {
        UUID().uuidString.lowercased()
    }

    public func jobDirectory(jobID: String) -> URL {
        rootURL.appendingPathComponent(safeJobID(jobID), isDirectory: true)
    }

    public func create(command: String, timeoutSeconds: TimeInterval?, label: String?, progressProbe: String?, runtime: String) throws -> WorkspaceManagedJobRecord {
        let jobID = makeJobID()
        let directory = jobDirectory(jobID: jobID)
        let layout = WorkspaceManagedJobFileLayout(directory: directory)
        try createTrustedDirectoryChain(to: directory)
        let commandURL = layout.command
        try ("#!/bin/sh\n" + command + "\n").write(to: commandURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandURL.path)

        let now = Date()
        let record = WorkspaceManagedJobRecord(
            jobID: jobID,
            command: command,
            label: label,
            progressProbe: progressProbe,
            runtime: runtime,
            status: .queued,
            createdAt: now,
            updatedAt: now,
            timeoutSeconds: timeoutSeconds,
            stdoutLogPath: layout.stdout.path,
            stderrLogPath: layout.stderr.path,
            heartbeatPath: layout.heartbeat.path,
            resultPath: layout.result.path
        )
        try save(record)
        return record
    }

    public func save(_ record: WorkspaceManagedJobRecord) throws {
        let directory = jobDirectory(jobID: record.jobID)
        var trustedRecord = record
        applyTrustedFileLayout(to: &trustedRecord, jobID: safeJobID(record.jobID), directory: directory)
        try createTrustedDirectoryChain(to: directory)
        let data = try encoder.encode(trustedRecord)
        try data.write(to: WorkspaceManagedJobFileLayout(directory: directory).metadata, options: [.atomic])
    }

    public func load(jobID: String) throws -> WorkspaceManagedJobRecord {
        let directory = jobDirectory(jobID: jobID)
        let metadataURL = WorkspaceManagedJobFileLayout(directory: directory).metadata
        if pathExistsWithoutFollowingSymlink(at: metadataURL) == false {
            throw jobNotFoundError(jobID: safeJobID(jobID))
        }
        guard let data = trustedFileData(at: metadataURL, inside: directory) else {
            throw trustedFileReadError(path: metadataURL.path)
        }
        var record = try decoder.decode(WorkspaceManagedJobRecord.self, from: data)
        applyTrustedFileLayout(to: &record, jobID: safeJobID(jobID), directory: directory)
        applyRuntimeFiles(to: &record, directory: directory)
        return record
    }

    public func tail(jobID: String, stream: String, lines: Int) throws -> WorkspaceManagedJobTail {
        let record = try load(jobID: jobID)
        let normalizedStream = stream.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let directory = jobDirectory(jobID: record.jobID)
        let layout = WorkspaceManagedJobFileLayout(directory: directory)
        let logURL = normalizedStream == "stderr" ? layout.stderr : layout.stdout
        let text = trustedLogText(at: logURL, inside: directory)
        return WorkspaceManagedJobTail(
            jobID: record.jobID,
            stream: normalizedStream == "stderr" ? "stderr" : "stdout",
            text: lastLines(text, count: lines)
        )
    }

    private func trustedLogText(at url: URL, inside directory: URL) -> String {
        guard let data = trustedFileData(at: url, inside: directory) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func trustedFileData(at url: URL, inside directory: URL) -> Data? {
        guard let expectedDirectoryStat = trustedDirectoryStat(at: directory),
              let expectedFileStat = trustedRegularFileStat(at: url, inside: directory) else {
            return nil
        }
        afterTrustedRegularFileStatForTesting?(url)

        let directoryFD = open(directory.standardizedFileURL.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard directoryFD >= 0 else {
            return nil
        }
        defer { close(directoryFD) }

        var openedDirectoryStat = stat()
        guard fstat(directoryFD, &openedDirectoryStat) == 0,
              sameFile(openedDirectoryStat, expectedDirectoryStat) else {
            return nil
        }

        let filename = url.lastPathComponent
        guard !filename.isEmpty,
              filename != ".",
              filename != ".." else {
            return nil
        }

        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }

        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFREG,
              statInfo.st_nlink == 1,
              sameFile(statInfo, expectedFileStat) else {
            return nil
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }

        return data
    }

    private func trustedFileModificationDate(at url: URL, inside directory: URL) -> Date? {
        guard let statInfo = trustedRegularFileStat(at: url, inside: directory) else {
            return nil
        }
#if canImport(Darwin)
        return Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec) + TimeInterval(statInfo.st_mtimespec.tv_nsec) / 1_000_000_000)
#elseif canImport(Glibc)
        return Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtim.tv_sec) + TimeInterval(statInfo.st_mtim.tv_nsec) / 1_000_000_000)
#else
        return nil
#endif
    }

    private func trustedRegularFileStat(at url: URL, inside directory: URL) -> stat? {
        let rootPath = rootURL.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        guard WorkspaceManagedJobPathContainment.isDescendant(directoryPath, of: rootPath),
              parentPath == directoryPath,
              isTrustedDirectoryChain(from: rootURL, to: directory) else {
            return nil
        }

        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFREG,
              statInfo.st_nlink == 1 else {
            return nil
        }
        return statInfo
    }

    public func validateJobRootForCreation() throws {
        try validateTrustedCreationPath(to: rootURL)
        if fileManager.fileExists(atPath: rootURL.path),
           trustedDirectoryStat(at: rootURL)?.st_nlink ?? 0 < 1 {
            throw trustedFileReadError(path: rootURL.path)
        }
    }

    private func createTrustedDirectoryChain(to directory: URL) throws {
        let anchor = trustedCreationAnchor(for: directory)
        try validateTrustedCreationPath(from: anchor, to: directory)

        var current = anchor.url.standardizedFileURL
        for component in relativePathComponents(from: anchor.url, to: directory) {
            current.appendPathComponent(component, isDirectory: true)
            if fileManager.fileExists(atPath: current.path) {
                guard isTrustedDirectory(current) else {
                    throw trustedFileReadError(path: current.path)
                }
                continue
            }

            try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            guard isTrustedDirectory(current) else {
                throw trustedFileReadError(path: current.path)
            }
        }
    }

    private func validateTrustedCreationPath(to directory: URL) throws {
        try validateTrustedCreationPath(from: trustedCreationAnchor(for: directory), to: directory)
    }

    private func validateTrustedCreationPath(from anchor: TrustedCreationAnchor, to directory: URL) throws {
        guard isTrustedCreationAnchor(anchor) else {
            throw trustedFileReadError(path: anchor.url.path)
        }

        var current = anchor.url.standardizedFileURL
        for component in relativePathComponents(from: anchor.url, to: directory) {
            current.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: current.path) else {
                continue
            }
            guard isTrustedDirectory(current) else {
                throw trustedFileReadError(path: current.path)
            }
        }
    }

    private struct TrustedCreationAnchor {
        var url: URL
        var allowsSymlinkedDirectory: Bool
    }

    private func trustedCreationAnchor(for directory: URL) -> TrustedCreationAnchor {
        if let astraAnchor = astraTasksAnchor(for: directory) {
            return TrustedCreationAnchor(url: astraAnchor, allowsSymlinkedDirectory: true)
        }

        var current = directory.standardizedFileURL
        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                return TrustedCreationAnchor(url: current, allowsSymlinkedDirectory: false)
            }
            current = parent
        }
        return TrustedCreationAnchor(url: current, allowsSymlinkedDirectory: false)
    }

    private func astraTasksAnchor(for directory: URL) -> URL? {
        let components = directory.standardizedFileURL.pathComponents
        guard components.count > 2 else { return nil }

        for index in components.indices.dropLast() where components[index] == ".astra" && components[index + 1] == "tasks" {
            guard index > 0 else { return nil }
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(index))), isDirectory: true)
        }
        return nil
    }

    private func relativePathComponents(from anchor: URL, to directory: URL) -> [String] {
        let anchorPath = anchor.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return WorkspaceManagedJobPathContainment.relativeComponents(from: anchorPath, to: directoryPath)
    }

    private func isTrustedDirectory(_ url: URL) -> Bool {
        trustedDirectoryStat(at: url) != nil
    }

    private func isTrustedCreationAnchor(_ anchor: TrustedCreationAnchor) -> Bool {
        if isTrustedDirectory(anchor.url) {
            return true
        }
        guard anchor.allowsSymlinkedDirectory else {
            return false
        }
        return resolvedDirectoryStat(at: anchor.url) != nil
    }

    private func trustedDirectoryStat(at url: URL) -> stat? {
        var statInfo = stat()
        guard lstat(url.standardizedFileURL.path, &statInfo) == 0 else {
            return nil
        }
        guard (statInfo.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return statInfo
    }

    private func resolvedDirectoryStat(at url: URL) -> stat? {
        var statInfo = stat()
        guard stat(url.standardizedFileURL.path, &statInfo) == 0 else {
            return nil
        }
        guard (statInfo.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return statInfo
    }

    private func pathExistsWithoutFollowingSymlink(at url: URL) -> Bool? {
        var statInfo = stat()
        if lstat(url.standardizedFileURL.path, &statInfo) == 0 {
            return true
        }
        if errno == ENOENT || errno == ENOTDIR {
            return false
        }
        return nil
    }

    private func isTrustedDirectoryChain(from root: URL, to directory: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        var current = directory.standardizedFileURL

        while current.path != rootPath {
            guard WorkspaceManagedJobPathContainment.isDescendant(current.path, of: rootPath),
                  isTrustedDirectory(current) else {
                return false
            }
            current.deleteLastPathComponent()
        }

        return isTrustedDirectory(root)
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func trustedFileReadError(path: String) -> Error {
        NSError(
            domain: "WorkspaceManagedJobStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Workspace job file is unsafe or unreadable: \(path)"]
        )
    }

    private func jobNotFoundError(jobID: String) -> Error {
        NSError(
            domain: "WorkspaceManagedJobStore",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Workspace job not found: \(jobID)"]
        )
    }

    public func mark(jobID: String, status: WorkspaceManagedJobStatus, message: String? = nil, exitCode: Int32? = nil) throws -> WorkspaceManagedJobRecord {
        var record = try load(jobID: jobID)
        record.status = status
        record.updatedAt = Date()
        if status != .queued && status != .running {
            record.completedAt = record.updatedAt
        }
        if let message {
            record.message = message
        }
        if let exitCode {
            record.exitCode = exitCode
        }
        try save(record)
        return record
    }

    private func applyRuntimeFiles(to record: inout WorkspaceManagedJobRecord, directory: URL) {
        let layout = WorkspaceManagedJobFileLayout(directory: directory)
        if let heartbeatData = trustedFileData(at: layout.heartbeat, inside: directory),
           let heartbeat = try? RuntimeHeartbeat.read(from: heartbeatData, decoder: decoder) {
            record.lastHeartbeatAt = heartbeat.timestamp
            if record.status == .queued {
                record.status = .running
            }
        }

        record.lastOutputAt = [layout.stdout, layout.stderr]
            .compactMap { trustedFileModificationDate(at: $0, inside: directory) }
            .max()

        if let resultData = trustedFileData(at: layout.result, inside: directory),
           let result = try? RuntimeResult.read(from: resultData, decoder: decoder) {
            record.status = result.status
            record.exitCode = result.exitCode
            record.completedAt = result.completedAt
            record.updatedAt = result.completedAt
            record.message = result.message ?? record.message
        }
    }

    private func applyTrustedFileLayout(to record: inout WorkspaceManagedJobRecord, jobID: String, directory: URL) {
        let layout = WorkspaceManagedJobFileLayout(directory: directory)
        record.jobID = jobID
        record.stdoutLogPath = layout.stdout.path
        record.stderrLogPath = layout.stderr.path
        record.heartbeatPath = layout.heartbeat.path
        record.resultPath = layout.result.path
    }

    private func safeJobID(_ raw: String) -> String {
        let filtered = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "unknown-job" : String(filtered.prefix(80))
    }

    private func lastLines(_ text: String, count: Int) -> String {
        let limit = max(1, min(count, 10_000))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.suffix(limit).joined(separator: "\n")
    }

    private struct RuntimeHeartbeat: Codable {
        var status: WorkspaceManagedJobStatus
        var timestamp: Date

        static func read(from data: Data, decoder: JSONDecoder) throws -> RuntimeHeartbeat {
            try decoder.decode(RuntimeHeartbeat.self, from: data)
        }
    }

    private struct RuntimeResult: Codable {
        var status: WorkspaceManagedJobStatus
        var exitCode: Int32?
        var completedAt: Date
        var message: String?

        static func read(from data: Data, decoder: JSONDecoder) throws -> RuntimeResult {
            try decoder.decode(RuntimeResult.self, from: data)
        }
    }

    private struct WorkspaceManagedJobFileLayout {
        var directory: URL

        var command: URL {
            directory.appendingPathComponent("command.sh", isDirectory: false)
        }

        var metadata: URL {
            directory.appendingPathComponent("job.json", isDirectory: false)
        }

        var stdout: URL {
            directory.appendingPathComponent("stdout.log", isDirectory: false)
        }

        var stderr: URL {
            directory.appendingPathComponent("stderr.log", isDirectory: false)
        }

        var heartbeat: URL {
            directory.appendingPathComponent("heartbeat.json", isDirectory: false)
        }

        var result: URL {
            directory.appendingPathComponent("result.json", isDirectory: false)
        }
    }
}

enum WorkspaceManagedJobPathContainment {
    static func isDescendant(_ candidatePath: String, of ancestorPath: String) -> Bool {
        guard candidatePath != ancestorPath else { return false }
        if ancestorPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath.hasPrefix(ancestorPath + "/")
    }

    static func relativeComponents(from ancestorPath: String, to candidatePath: String) -> [String] {
        guard isDescendant(candidatePath, of: ancestorPath) else {
            return []
        }

        let dropCount = ancestorPath == "/" ? 1 : ancestorPath.count + 1
        return String(candidatePath.dropFirst(dropCount))
            .split(separator: "/")
            .map(String.init)
    }
}

public final class DockerWorkspaceJobManager: WorkspaceJobManaging {
    private let configuration: WorkspaceToolConfiguration
    private let executor: DockerWorkspaceCommandExecutor
    private let store: WorkspaceManagedJobStore

    public init(configuration: WorkspaceToolConfiguration, executor: DockerWorkspaceCommandExecutor) {
        self.configuration = configuration
        self.executor = executor
        self.store = WorkspaceManagedJobStore(rootPath: configuration.jobRootHostPath)
    }

    public func start(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?
    ) -> WorkspaceManagedJobRecord {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return failedSynthetic(command: command, message: "workspace_job_start requires a non-empty command")
        }
        let pathResolution = configuration.containerCommand(for: trimmed)
        if let errorMessage = pathResolution.errorMessage {
            return failedSynthetic(command: command, message: errorMessage)
        }
        do {
            try store.validateJobRootForCreation()
        } catch {
            return failedSynthetic(command: command, message: error.localizedDescription)
        }
        let container = executor.ensureContainerStarted()
        guard container.exitCode == 0 else {
            return failedSynthetic(
                command: command,
                message: container.stderr.isEmpty ? "Failed to start Docker workspace container" : container.stderr
            )
        }

        do {
            var record = try store.create(
                command: pathResolution.command,
                timeoutSeconds: timeoutSeconds,
                label: label,
                progressProbe: progressProbe,
                runtime: "docker"
            )
            record.status = .running
            record.startedAt = Date()
            record.updatedAt = record.startedAt ?? record.updatedAt
            try store.save(record)

            let result = executor.runDockerCommand(
                arguments: [
                    "exec", "-d",
                    "--workdir", configuration.workdir,
                    configuration.containerName,
                    "sh", "-c", wrapperScript(
                        containerJobDirectory: containerJobDirectory(jobID: record.jobID),
                        timeoutSeconds: timeoutSeconds
                    )
                ],
                commandLabel: "workspace_job_start \(record.jobID)",
                timeoutSeconds: 30
            )
            guard result.exitCode == 0 else {
                return try store.mark(
                    jobID: record.jobID,
                    status: .failed,
                    message: result.stderr.isEmpty ? "Docker could not start the managed workspace job." : result.stderr,
                    exitCode: result.exitCode
                )
            }
            return try store.load(jobID: record.jobID)
        } catch {
            return failedSynthetic(command: command, message: error.localizedDescription)
        }
    }

    public func status(jobID: String) -> WorkspaceManagedJobRecord {
        do {
            return try store.load(jobID: jobID)
        } catch {
            return failedSynthetic(command: "", jobID: jobID, message: error.localizedDescription)
        }
    }

    public func tail(jobID: String, stream: String, lines: Int) -> WorkspaceManagedJobTail {
        do {
            return try store.tail(jobID: jobID, stream: stream, lines: lines)
        } catch {
            return WorkspaceManagedJobTail(jobID: jobID, stream: stream, text: error.localizedDescription)
        }
    }

    public func cancel(jobID: String) -> WorkspaceManagedJobRecord {
        let directory = containerJobDirectory(jobID: jobID)
        _ = executor.runDockerCommand(
            arguments: [
                "exec", configuration.containerName,
                "sh", "-c",
                "if [ -r \(shellQuote(directory + "/pid")) ]; then kill -TERM \"$(cat \(shellQuote(directory + "/pid")))\" 2>/dev/null || true; fi"
            ],
            commandLabel: "workspace_job_cancel \(jobID)",
            timeoutSeconds: 10
        )
        do {
            return try store.mark(jobID: jobID, status: .cancelled, message: "Cancelled by ASTRA.")
        } catch {
            return failedSynthetic(command: "", jobID: jobID, message: error.localizedDescription)
        }
    }

    public func wait(jobID: String, timeoutSeconds: TimeInterval) -> WorkspaceManagedJobRecord {
        let deadline = Date().addingTimeInterval(max(1, timeoutSeconds))
        var latest = status(jobID: jobID)
        while !latest.isTerminal && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            latest = status(jobID: jobID)
        }
        return latest
    }

    private func containerJobDirectory(jobID: String) -> String {
        configuration.jobRootContainerPath + "/" + jobID
    }

    private func wrapperScript(containerJobDirectory: String, timeoutSeconds: TimeInterval?) -> String {
        let dir = shellQuote(containerJobDirectory)
        let timeout = max(0, Int((timeoutSeconds ?? 0).rounded(.up)))
        return """
        job_dir=\(dir)
        timeout_seconds=\(timeout)
        stdout="$job_dir/stdout.log"
        stderr="$job_dir/stderr.log"
        heartbeat="$job_dir/heartbeat.json"
        result="$job_dir/result.json"
        pidfile="$job_dir/pid"
        timeout_marker="$job_dir/timeout"
        mkdir -p "$job_dir"
        rm -f "$timeout_marker"
        (
          while :; do
            printf '{"status":"running","timestamp":"%s"}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$heartbeat"
            sleep 10
          done
        ) &
        heartbeat_pid=$!
        sh "$job_dir/command.sh" > "$stdout" 2> "$stderr" &
        command_pid=$!
        printf '%s\\n' "$command_pid" > "$pidfile"
        timeout_pid=""
        if [ "$timeout_seconds" -gt 0 ]; then
          (
            sleep "$timeout_seconds"
            if kill -0 "$command_pid" 2>/dev/null; then
              printf '%s\\n' timed_out > "$timeout_marker"
              kill -TERM "$command_pid" 2>/dev/null || true
              sleep 5
              kill -KILL "$command_pid" 2>/dev/null || true
            fi
          ) &
          timeout_pid=$!
        fi
        wait "$command_pid"
        code=$?
        if [ -n "$timeout_pid" ]; then
          kill "$timeout_pid" 2>/dev/null || true
          wait "$timeout_pid" 2>/dev/null || true
        fi
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
        status=failed
        if [ "$code" -eq 0 ]; then status=succeeded; fi
        if [ -f "$timeout_marker" ]; then status=timed_out; code=124; fi
        printf '{"status":"%s","exitCode":%s,"completedAt":"%s"}\\n' "$status" "$code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$result"
        printf '{"status":"%s","timestamp":"%s"}\\n' "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$heartbeat"
        exit 0
        """
    }

    private func failedSynthetic(command: String, jobID: String = "unstarted", message: String) -> WorkspaceManagedJobRecord {
        let now = Date()
        return WorkspaceManagedJobRecord(
            jobID: jobID,
            command: command,
            runtime: "docker",
            status: .failed,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            exitCode: 2,
            stdoutLogPath: "",
            stderrLogPath: "",
            heartbeatPath: "",
            resultPath: "",
            message: message
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
