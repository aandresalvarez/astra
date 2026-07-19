import Foundation
import ASTRACore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

public enum WorkspaceManagedJobStoreError: LocalizedError, Sendable {
    case invalidJobID

    public var errorDescription: String? {
        switch self {
        case .invalidJobID:
            return "Invalid workspace job id."
        }
    }
}

public protocol WorkspaceJobManaging: AnyObject {
    func start(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?,
        invocationID: String
    ) -> WorkspaceManagedJobRecord
    func status(jobID: String) -> WorkspaceManagedJobRecord
    func tail(jobID: String, stream: String, lines: Int) -> WorkspaceManagedJobTail
    func cancel(jobID: String) -> WorkspaceManagedJobRecord
    func wait(jobID: String, timeoutSeconds: TimeInterval) -> WorkspaceManagedJobRecord
    /// Fails closed: true means session cleanup must not stop the executor
    /// container because it may still own approved external work.
    func hasTrustedNonterminalOwnedJob() -> Bool
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

    public func canonicalJobID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            throw WorkspaceManagedJobStoreError.invalidJobID
        }
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return (65...90).contains(value) ||
                (97...122).contains(value) ||
                (48...57).contains(value) ||
                value == 45 ||
                value == 95
        }) else {
            throw WorkspaceManagedJobStoreError.invalidJobID
        }
        return trimmed.lowercased()
    }

    public func jobDirectory(jobID: String) throws -> URL {
        let canonicalID = try canonicalJobID(jobID)
        return jobDirectory(forCanonicalID: canonicalID)
    }

    public func create(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?,
        runtime: String,
        taskID: String,
        runID: String,
        invocationID: String,
        containerName: String
    ) throws -> WorkspaceManagedJobRecord {
        let jobID = makeJobID()
        let directory = try jobDirectory(jobID: jobID)
        let layout = WorkspaceManagedJobFileLayout(directory: directory)
        let receipt = try WorkspaceManagedJobStartReceipt.make(
            taskID: taskID,
            runID: runID,
            invocationID: invocationID,
            containerName: containerName,
            jobID: jobID
        )
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
            resultPath: layout.result.path,
            startReceipt: receipt
        )
        try save(record)
        return record
    }

    public func save(_ record: WorkspaceManagedJobRecord) throws {
        let canonicalID = try canonicalJobID(record.jobID)
        try record.startReceipt?.validate(jobID: canonicalID)
        let directory = jobDirectory(forCanonicalID: canonicalID)
        var trustedRecord = record
        applyTrustedFileLayout(to: &trustedRecord, jobID: canonicalID, directory: directory)
        try createTrustedDirectoryChain(to: directory)
        let data = try encoder.encode(trustedRecord)
        try data.write(to: WorkspaceManagedJobFileLayout(directory: directory).metadata, options: [.atomic])
    }

    public func load(jobID: String) throws -> WorkspaceManagedJobRecord {
        let canonicalID = try canonicalJobID(jobID)
        let directory = jobDirectory(forCanonicalID: canonicalID)
        let metadataURL = WorkspaceManagedJobFileLayout(directory: directory).metadata
        if pathExistsWithoutFollowingSymlink(at: metadataURL) == false {
            throw jobNotFoundError(jobID: canonicalID)
        }
        guard let data = trustedFileData(at: metadataURL, inside: directory) else {
            throw trustedFileReadError(path: metadataURL.path)
        }
        var record = try decoder.decode(WorkspaceManagedJobRecord.self, from: data)
        guard (try? canonicalJobID(record.jobID)) == canonicalID else {
            throw WorkspaceManagedJobStoreError.invalidJobID
        }
        try record.startReceipt?.validate(jobID: canonicalID)
        applyTrustedFileLayout(to: &record, jobID: canonicalID, directory: directory)
        applyRuntimeFiles(to: &record, directory: directory)
        return record
    }

    /// Lists records only through the same trusted directory/file boundary as
    /// direct lookup. A malformed or substituted candidate fails the whole
    /// listing so cleanup preserves the container rather than risking a kill.
    public func listTrustedRecords() throws -> [WorkspaceManagedJobRecord] {
        switch pathExistsWithoutFollowingSymlink(at: rootURL) {
        case false:
            return []
        case nil:
            throw trustedFileReadError(path: rootURL.path)
        case true:
            guard trustedDirectoryStat(at: rootURL) != nil else {
                throw trustedFileReadError(path: rootURL.path)
            }
        }

        let entries = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [WorkspaceManagedJobRecord] = []
        var ownerInvocations: Set<String> = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard (try? canonicalJobID(name)) == name,
                  trustedDirectoryStat(at: entry) != nil else {
                throw trustedFileReadError(path: entry.path)
            }
            let record = try load(jobID: name)
            if let receipt = record.startReceipt {
                let ownerInvocation = [
                    receipt.taskID.uuidString.lowercased(),
                    receipt.runID.uuidString.lowercased(),
                    receipt.invocationID,
                    receipt.containerName
                ].joined(separator: "|")
                guard ownerInvocations.insert(ownerInvocation).inserted else {
                    throw trustedFileReadError(path: entry.path)
                }
            }
            records.append(record)
        }
        return records
    }

    private func jobDirectory(forCanonicalID canonicalID: String) -> URL {
        rootURL.appendingPathComponent(canonicalID, isDirectory: true)
    }

    public func tail(jobID: String, stream: String, lines: Int) throws -> WorkspaceManagedJobTail {
        let record = try load(jobID: jobID)
        let normalizedStream = stream.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let directory = try jobDirectory(jobID: record.jobID)
        let layout = WorkspaceManagedJobFileLayout(directory: directory)
        let logURL = normalizedStream == "stderr" ? layout.stderr : layout.stdout
        let text = trustedLogTailText(at: logURL, inside: directory, lines: lines)
        return WorkspaceManagedJobTail(
            jobID: record.jobID,
            stream: normalizedStream == "stderr" ? "stderr" : "stdout",
            text: text
        )
    }

    private func trustedLogTailText(at url: URL, inside directory: URL, lines: Int) -> String {
        withTrustedFileDescriptor(at: url, inside: directory) { fd in
            WorkspaceManagedJobLogTailReader.tail(fileDescriptor: fd, lines: lines)
        } ?? ""
    }

    private func trustedFileData(at url: URL, inside directory: URL) -> Data? {
        withTrustedFileDescriptor(at: url, inside: directory) { fd in
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
    }

    private func withTrustedFileDescriptor<T>(
        at url: URL,
        inside directory: URL,
        _ body: (Int32) -> T?
    ) -> T? {
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

        return body(fd)
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

private enum WorkspaceManagedJobLogTailReader {
    private static let maximumLineCount = 10_000
    private static let minimumReadBytes = 64 * 1024
    private static let bytesPerRequestedLine = 1024
    private static let maximumReadBytes = 4 * 1024 * 1024

    static func tail(fileDescriptor: Int32, lines: Int) -> String {
        let lineLimit = max(1, min(lines, maximumLineCount))
        let byteLimit = max(
            minimumReadBytes,
            min(maximumReadBytes, lineLimit * bytesPerRequestedLine)
        )
        guard let suffix = readSuffix(fileDescriptor: fileDescriptor, byteLimit: byteLimit) else {
            return ""
        }
        let tailData = lastLines(
            dropPartialLeadingLineIfNeeded(suffix.data, startsInsideLine: suffix.startsInsideLine),
            count: lineLimit
        )
        return decodeBounded(tailData, byteLimit: byteLimit)
    }

    private static func readSuffix(fileDescriptor fd: Int32, byteLimit: Int) -> LogSuffix? {
        let fileSize = lseek(fd, 0, SEEK_END)
        guard fileSize >= 0 else {
            return nil
        }

        let bytesToRead = min(Int64(byteLimit), Int64(fileSize))
        let startOffset = Int64(fileSize) - bytesToRead
        let startsInsideLine: Bool
        if startOffset > 0 {
            guard lseek(fd, off_t(startOffset - 1), SEEK_SET) >= 0 else {
                return nil
            }
            var byte = [UInt8](repeating: 0, count: 1)
            let previousByte = read(fd, &byte, 1) == 1 ? byte[0] : nil
            startsInsideLine = WorkspaceManagedJobLogTailPolicy.startsInsideLine(previousByte: previousByte)
        } else {
            startsInsideLine = false
        }

        guard lseek(fd, off_t(startOffset), SEEK_SET) >= 0 else {
            return nil
        }

        var data = Data()
        var remaining = Int(bytesToRead)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, remaining)))
        while remaining > 0 {
            let bytesRead = read(fd, &buffer, min(buffer.count, remaining))
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
                remaining -= bytesRead
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }

        return LogSuffix(data: data, startsInsideLine: startsInsideLine)
    }

    private static func dropPartialLeadingLineIfNeeded(_ data: Data, startsInsideLine: Bool) -> Data {
        guard startsInsideLine, let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            return data
        }
        let completeLineStart = data.index(after: newline)
        guard completeLineStart < data.endIndex else {
            return data
        }
        return Data(data[completeLineStart...])
    }

    private static func lastLines(_ data: Data, count: Int) -> Data {
        var end = data.endIndex
        if end > data.startIndex, data[data.index(before: end)] == UInt8(ascii: "\n") {
            end = data.index(before: end)
        }
        var remainingNewlines = count
        var cursor = end
        while cursor > data.startIndex {
            let previous = data.index(before: cursor)
            if data[previous] == UInt8(ascii: "\n") {
                remainingNewlines -= 1
                if remainingNewlines == 0 {
                    return Data(data[data.index(after: previous)..<end])
                }
            }
            cursor = previous
        }
        return Data(data[..<end])
    }

    private static func decodeBounded(_ data: Data, byteLimit: Int) -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.count > byteLimit else {
            return text
        }
        return suffixFittingUTF8Bytes(text, byteLimit: byteLimit)
    }

    private static func suffixFittingUTF8Bytes(_ text: String, byteLimit: Int) -> String {
        guard byteLimit > 0 else {
            return ""
        }
        let utf8 = text.utf8
        var start = utf8.index(utf8.endIndex, offsetBy: -byteLimit)
        while start < utf8.endIndex {
            if let stringStart = String.Index(start, within: text) {
                return String(text[stringStart...])
            }
            utf8.formIndex(after: &start)
        }
        return ""
    }

    private struct LogSuffix {
        var data: Data
        var startsInsideLine: Bool
    }
}

enum WorkspaceManagedJobLogTailPolicy {
    static func startsInsideLine(previousByte: UInt8?) -> Bool {
        guard let previousByte else {
            return false
        }
        return previousByte != UInt8(ascii: "\n")
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
        progressProbe: String?,
        invocationID: String
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
            _ = try WorkspaceManagedJobStartReceipt.make(
                taskID: configuration.taskID,
                runID: configuration.runID,
                invocationID: invocationID,
                containerName: configuration.containerName,
                jobID: "preflight"
            )
            if let existing = try existingRecord(invocationID: invocationID) {
                return existing
            }
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
                runtime: "docker",
                taskID: configuration.taskID,
                runID: configuration.runID,
                invocationID: invocationID,
                containerName: configuration.containerName
            )

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
            record.status = .running
            record.startedAt = Date()
            record.updatedAt = record.startedAt ?? record.updatedAt
            try store.save(record)
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
        do {
            let record = try store.load(jobID: jobID)
            // If the job already reached a terminal result between the last poll
            // and this cancel, return that authoritative result unchanged rather
            // than issuing a kill and rewriting it to .cancelled — otherwise a
            // job that actually succeeded/failed would be routed to cancellation
            // instead of completion validation.
            guard !record.isTerminal else { return record }
            let directory = containerJobDirectory(jobID: record.jobID)
            let cancelResult = executor.runDockerCommand(
                arguments: [
                    "exec", configuration.containerName,
                    "sh", "-c",
                    """
                    pidfile=\(shellQuote(directory + "/pid"))
                    pid_metadata=\(shellQuote(directory + "/pid.meta"))
                    pid_metadata_tmp="$pid_metadata.tmp"
                    command_script=\(shellQuote(directory + "/command.sh"))
                    kill_bin=""
                    for candidate in /bin/kill /usr/bin/kill /usr/local/bin/kill; do
                      if [ -x "$candidate" ]; then
                        kill_bin="$candidate"
                        break
                      fi
                    done
                    safe_pid() {
                      case "$1" in
                        ''|*[!0-9]*) return 1 ;;
                      esac
                      [ "$1" -gt 1 ] 2>/dev/null
                    }
                    proc_start_time() {
                      safe_pid "$1" || return 1
                      [ -r "/proc/$1/stat" ] || return 1
                      stat_line="$(cat "/proc/$1/stat" 2>/dev/null || true)"
                      stat_rest="${stat_line##*) }"
                      set -- $stat_rest
                      [ "$#" -ge 20 ] || return 1
                      shift 19
                      printf '%s\\n' "$1"
                    }
                    proc_is_session_group_leader() {
                      target_pid="$1"
                      safe_pid "$target_pid" || return 1
                      [ -r "/proc/$target_pid/stat" ] || return 1
                      stat_line="$(cat "/proc/$target_pid/stat" 2>/dev/null || true)"
                      stat_rest="${stat_line##*) }"
                      set -- $stat_rest
                      [ "$#" -ge 4 ] || return 1
                      [ "$3" = "$target_pid" ] && [ "$4" = "$target_pid" ]
                    }
                    pid_matches_managed_command() {
                      safe_pid "$1" || return 1
                      [ -r "/proc/$1/cmdline" ] || return 1
                      cmdline="$(tr '\\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || cat "/proc/$1/cmdline" 2>/dev/null || true)"
                      case "$cmdline" in
                        *"$command_script"*) return 0 ;;
                        *) return 1 ;;
                      esac
                    }
                    pid_matches_managed_session() {
                      safe_pid "$1" || return 1
                      [ -r "$pid_metadata" ] || return 1
                      managed_pid=""
                      managed_mode=""
                      managed_start_time=""
                      while IFS='=' read -r key value; do
                        case "$key" in
                          pid) managed_pid="$value" ;;
                          mode) managed_mode="$value" ;;
                          start_time) managed_start_time="$value" ;;
                        esac
                      done < "$pid_metadata"
                      [ "$managed_pid" = "$1" ] || return 1
                      [ "$managed_mode" = "setsid-process-group" ] || return 1
                      [ -n "$managed_start_time" ] || return 1
                      current_start_time="$(proc_start_time "$1" || true)"
                      [ "$managed_start_time" = "$current_start_time" ] || return 1
                      proc_is_session_group_leader "$1"
                    }
                    pid_metadata_names_managed_group() {
                      safe_pid "$1" || return 1
                      [ -r "$pid_metadata" ] || return 1
                      managed_pid=""
                      managed_mode=""
                      managed_start_time=""
                      while IFS='=' read -r key value; do
                        case "$key" in
                          pid) managed_pid="$value" ;;
                          mode) managed_mode="$value" ;;
                          start_time) managed_start_time="$value" ;;
                        esac
                      done < "$pid_metadata"
                      [ "$managed_pid" = "$1" ] || return 1
                      [ "$managed_mode" = "setsid-process-group" ]
                      [ -n "$managed_start_time" ] || return 1
                    }
                    process_group_exists() {
                      group_pid="$1"
                      safe_pid "$group_pid" || return 1
                      if [ -n "$kill_bin" ] && "$kill_bin" -0 -- -"$group_pid" 2>/dev/null; then
                        return 0
                      fi
                      kill -0 -"$group_pid" 2>/dev/null
                    }
                    signal_process_group() {
                      signal="$1"
                      group_pid="$2"
                      safe_pid "$group_pid" || return 0
                      if [ -n "$kill_bin" ] && "$kill_bin" -"$signal" -- -"$group_pid" 2>/dev/null; then
                        return 0
                      fi
                      kill -"$signal" -"$group_pid" 2>/dev/null || true
                    }
                    signal_direct_pid() {
                      signal="$1"
                      target_pid="$2"
                      safe_pid "$target_pid" || return 0
                      kill -"$signal" "$target_pid" 2>/dev/null || true
                    }
                    terminate_verified_process_group() {
                      group_pid="$1"
                      if process_group_exists "$group_pid"; then
                        signal_process_group TERM "$group_pid"
                        sleep 5
                        signal_process_group KILL "$group_pid"
                      fi
                    }
                    terminate_direct_pid() {
                      target_pid="$1"
                      if kill -0 "$target_pid" 2>/dev/null; then
                        signal_direct_pid TERM "$target_pid"
                        sleep 5
                        signal_direct_pid KILL "$target_pid"
                      fi
                    }
                    terminate_pid_or_group() {
                      target_pid="$1"
                      safe_pid "$target_pid" || return 0
                      if pid_metadata_names_managed_group "$target_pid"; then
                        if kill -0 "$target_pid" 2>/dev/null; then
                          if pid_matches_managed_session "$target_pid"; then
                            if process_group_exists "$target_pid"; then
                              terminate_verified_process_group "$target_pid"
                            else
                              terminate_direct_pid "$target_pid"
                            fi
                          fi
                        elif process_group_exists "$target_pid"; then
                          terminate_verified_process_group "$target_pid"
                        fi
                      elif pid_matches_managed_command "$target_pid"; then
                        if proc_is_session_group_leader "$target_pid"; then
                          terminate_verified_process_group "$target_pid"
                        else
                          terminate_direct_pid "$target_pid"
                        fi
                      elif [ ! -e "$pid_metadata" ] && kill -0 "$target_pid" 2>/dev/null; then
                        terminate_direct_pid "$target_pid"
                      fi
                    }
                    if [ -r "$pidfile" ]; then
                      IFS= read -r command_pid < "$pidfile" || command_pid=""
                      terminate_pid_or_group "$command_pid"
                      rm -f "$pidfile" "$pid_metadata" "$pid_metadata_tmp"
                    fi
                    """
                ],
                commandLabel: "workspace_job_cancel \(record.jobID)",
                timeoutSeconds: 10
            )
            // A transient exec failure (daemon/socket hiccup, container briefly
            // unreachable, or a timed-out kill) must NOT be rewritten to
            // `.cancelled`: the managed process may still be running, and a false
            // terminal status would stop all monitoring while the job continues.
            // Only finalize cancellation when the kill command actually
            // succeeded; otherwise return the unmodified record so the caller
            // keeps observing the still-live job and can retry.
            guard cancelResult.exitCode == 0, !cancelResult.timedOut else {
                return record
            }
            return try store.mark(jobID: record.jobID, status: .cancelled, message: "Cancelled by ASTRA.")
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

    public func hasTrustedNonterminalOwnedJob() -> Bool {
        do {
            return try store.listTrustedRecords().contains { record in
                guard !record.isTerminal, let receipt = record.startReceipt else {
                    return false
                }
                return receipt.belongsTo(
                    taskID: configuration.taskID,
                    runID: configuration.runID,
                    containerName: configuration.containerName
                )
            }
        } catch {
            // Cleanup is destructive. If the trusted listing cannot prove the
            // container idle, preserve it and let deterministic reconciliation
            // resolve ownership later.
            return true
        }
    }

    /// Stops the task/run-scoped local executor only after the trusted backend
    /// records prove that it owns no nonterminal work. Listing failures are
    /// fail-closed and preserve the container.
    @discardableResult
    public func cleanupExecutorIfIdle() -> Bool {
        guard !hasTrustedNonterminalOwnedJob() else { return false }
        return executor.stopManagedContainerIfPresent()
    }

    private func existingRecord(invocationID: String) throws -> WorkspaceManagedJobRecord? {
        try store.listTrustedRecords().first { record in
            guard let receipt = record.startReceipt else { return false }
            return receipt.invocationID == invocationID
                && receipt.belongsTo(
                    taskID: configuration.taskID,
                    runID: configuration.runID,
                    containerName: configuration.containerName
                )
        }
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
        pid_metadata="$job_dir/pid.meta"
        pid_metadata_tmp="$pid_metadata.tmp"
        timeout_marker="$job_dir/timeout"
        mkdir -p "$job_dir"
        rm -f "$timeout_marker" "$pidfile" "$pid_metadata" "$pid_metadata_tmp"
        kill_bin=""
        for candidate in /bin/kill /usr/bin/kill /usr/local/bin/kill; do
          if [ -x "$candidate" ]; then
            kill_bin="$candidate"
            break
          fi
        done
        setsid_bin=""
        for candidate in /usr/bin/setsid /bin/setsid /usr/sbin/setsid /sbin/setsid /usr/local/bin/setsid; do
          if [ -x "$candidate" ]; then
            setsid_bin="$candidate"
            break
          fi
        done
        (
          while :; do
            printf '{"status":"running","timestamp":"%s"}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$heartbeat"
            sleep 10
          done
        ) &
        heartbeat_pid=$!
        if [ -z "$setsid_bin" ]; then
          printf '%s\\n' "setsid is required for managed job process-group isolation." > "$stderr"
          kill "$heartbeat_pid" 2>/dev/null || true
          wait "$heartbeat_pid" 2>/dev/null || true
          printf '{"status":"failed","exitCode":127,"completedAt":"%s","message":"process group isolation unavailable"}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$result"
          printf '{"status":"failed","timestamp":"%s"}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$heartbeat"
          exit 0
        fi
        safe_pid() {
          case "$1" in
            ''|*[!0-9]*) return 1 ;;
          esac
          [ "$1" -gt 1 ] 2>/dev/null
        }
        proc_start_time() {
          safe_pid "$1" || return 1
          [ -r "/proc/$1/stat" ] || return 1
          stat_line="$(cat "/proc/$1/stat" 2>/dev/null || true)"
          stat_rest="${stat_line##*) }"
          set -- $stat_rest
          [ "$#" -ge 20 ] || return 1
          shift 19
          printf '%s\\n' "$1"
        }
        "$setsid_bin" sh "$job_dir/command.sh" > "$stdout" 2> "$stderr" &
        command_pid=$!
        printf '%s\\n' "$command_pid" > "$pidfile"
        command_start_time="$(proc_start_time "$command_pid" || true)"
        if [ -n "$command_start_time" ]; then
          {
            printf 'version=1\\n'
            printf 'mode=setsid-process-group\\n'
            printf 'pid=%s\\n' "$command_pid"
            printf 'start_time=%s\\n' "$command_start_time"
          } > "$pid_metadata_tmp"
          mv -f "$pid_metadata_tmp" "$pid_metadata"
        else
          rm -f "$pid_metadata" "$pid_metadata_tmp"
        fi
        process_group_exists() {
          group_pid="$1"
          safe_pid "$group_pid" || return 1
          if [ -n "$kill_bin" ] && "$kill_bin" -0 -- -"$group_pid" 2>/dev/null; then
            return 0
          fi
          kill -0 -"$group_pid" 2>/dev/null
        }
        signal_process_group() {
          signal="$1"
          group_pid="$2"
          safe_pid "$group_pid" || return 0
          if [ -n "$kill_bin" ] && "$kill_bin" -"$signal" -- -"$group_pid" 2>/dev/null; then
            return 0
          fi
          kill -"$signal" -"$group_pid" 2>/dev/null || true
        }
        terminate_command_group() {
          grace_seconds="${1:-5}"
          safe_pid "$command_pid" || return 0
          if process_group_exists "$command_pid"; then
            signal_process_group TERM "$command_pid"
            sleep "$grace_seconds"
            signal_process_group KILL "$command_pid"
          fi
        }
        command_leader_matches_start_time() {
          safe_pid "$command_pid" || return 1
          kill -0 "$command_pid" 2>/dev/null || return 1
          if [ -n "$command_start_time" ]; then
            current_start_time="$(proc_start_time "$command_pid" || true)"
            [ "$command_start_time" = "$current_start_time" ] || return 1
          fi
          return 0
        }
        timeout_pid=""
        if [ "$timeout_seconds" -gt 0 ]; then
          (
            sleep "$timeout_seconds"
            if command_leader_matches_start_time && process_group_exists "$command_pid"; then
              printf '%s\\n' timed_out > "$timeout_marker"
              terminate_command_group 5
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
        terminate_command_group 1
        rm -f "$pidfile" "$pid_metadata" "$pid_metadata_tmp"
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
