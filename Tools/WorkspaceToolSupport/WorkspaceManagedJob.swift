import Foundation
import ASTRACore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `flock` protects separate processes, but Darwin treats locks acquired by the
/// same process as cooperating ownership. Serialize in-process admissions too.
private let workspaceManagedJobAdmissionProcessLock = NSLock()

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

public struct WorkspaceManagedJobAdmission: Sendable {
    public var record: WorkspaceManagedJobRecord
    public var isNew: Bool

    public init(record: WorkspaceManagedJobRecord, isNew: Bool) {
        self.record = record
        self.isNew = isNew
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
    /// Fails closed: true means provider cleanup must preserve the executor
    /// because it may still own admitted external work.
    func hasTrustedNonterminalOwnedJob() -> Bool
    /// Runs the destructive executor cleanup, when safe, inside the same
    /// cross-process exclusion boundary used by managed-job admission.
    @discardableResult
    func cleanupExecutorIfIdle(_ cleanup: () -> Void) -> Bool
}

public extension WorkspaceJobManaging {
    /// Compatibility entry point for non-MCP callers. New durable callers must
    /// pass the stable, type-tagged invocation ID received from MCPServerKit.
    func start(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?
    ) -> WorkspaceManagedJobRecord {
        start(
            command: command,
            timeoutSeconds: timeoutSeconds,
            label: label,
            progressProbe: progressProbe,
            invocationID: "legacy:\(UUID().uuidString.lowercased())"
        )
    }

    func hasTrustedNonterminalOwnedJob() -> Bool { true }

    @discardableResult
    func cleanupExecutorIfIdle(_ cleanup: () -> Void) -> Bool {
        guard !hasTrustedNonterminalOwnedJob() else { return false }
        cleanup()
        return true
    }
}

public final class WorkspaceManagedJobStore {
    private let rootURL: URL
    private let trustedStateRootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    var afterTrustedRegularFileStatForTesting: ((URL) -> Void)?
    var afterLaunchBeforeSaveForTesting: (() throws -> Void)?
    var beforeProviderProjectionWriteForTesting: ((URL) throws -> Void)?

    public init(
        rootPath: String,
        trustedStateRootPath: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        self.trustedStateRootURL = URL(
            fileURLWithPath: trustedStateRootPath ?? rootPath,
            isDirectory: true
        )
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

    public func create(command: String, timeoutSeconds: TimeInterval?, label: String?, progressProbe: String?, runtime: String) throws -> WorkspaceManagedJobRecord {
        let jobID = makeJobID()
        let directory = try jobDirectory(jobID: jobID)
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
        try createAdmittedRecord(
            command: command,
            timeoutSeconds: timeoutSeconds,
            label: label,
            progressProbe: progressProbe,
            runtime: runtime,
            taskID: taskID,
            runID: runID,
            invocationID: invocationID,
            containerName: containerName,
            trustedLockHeld: false
        )
    }

    private func createAdmittedRecord(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?,
        runtime: String,
        taskID: String,
        runID: String,
        invocationID: String,
        containerName: String,
        trustedLockHeld: Bool
    ) throws -> WorkspaceManagedJobRecord {
        let jobID = makeJobID()
        let directory = try jobDirectory(jobID: jobID)
        let layout = WorkspaceManagedJobFileLayout(directory: directory)
        let receipt = try WorkspaceManagedJobStartReceipt.make(
            taskID: taskID,
            runID: runID,
            invocationID: invocationID,
            requestFingerprint: try WorkspaceManagedJobRequestFingerprint.make(
                command: command,
                timeoutSeconds: timeoutSeconds,
                label: label,
                progressProbe: progressProbe
            ),
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
        if trustedLockHeld {
            try save(record, trustedLockHeld: true)
        } else {
            try save(record)
        }
        return record
    }

    /// Atomically adopts or creates one invocation receipt across provider/MCP
    /// processes. `flock` ownership is released by the kernel after crashes.
    /// The lock covers lookup plus durable queued-record creation. The launch
    /// path upgrades that receipt to a durable `.launching` fence before the
    /// detached effect, so an ambiguous crash cannot permit a duplicate launch.
    public func admitInvocation(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?,
        runtime: String,
        taskID: String,
        runID: String,
        invocationID: String,
        containerName: String
    ) throws -> WorkspaceManagedJobAdmission {
        let requestFingerprint = try WorkspaceManagedJobRequestFingerprint.make(
            command: command,
            timeoutSeconds: timeoutSeconds,
            label: label,
            progressProbe: progressProbe
        )
        return try withInvocationAdmissionLock {
            if let existing = try listTrustedRecordsUnlocked().first(where: { record in
                guard let receipt = record.startReceipt else { return false }
                return receipt.invocationID == invocationID
                    && receipt.belongsTo(
                        taskID: taskID,
                        runID: runID,
                        containerName: containerName
                    )
            }) {
                guard existing.startReceipt?.requestFingerprint == requestFingerprint else {
                    throw WorkspaceManagedJobContractError.invocationPayloadMismatch
                }
                return WorkspaceManagedJobAdmission(record: existing, isNew: false)
            }
            return WorkspaceManagedJobAdmission(
                record: try createAdmittedRecord(
                    command: command,
                    timeoutSeconds: timeoutSeconds,
                    label: label,
                    progressProbe: progressProbe,
                    runtime: runtime,
                    taskID: taskID,
                    runID: runID,
                    invocationID: invocationID,
                    containerName: containerName,
                    trustedLockHeld: true
                ),
                isNew: true
            )
        }
    }

    public func save(_ record: WorkspaceManagedJobRecord) throws {
        try withInvocationAdmissionLock {
            try save(record, trustedLockHeld: true)
        }
    }

    private func save(_ record: WorkspaceManagedJobRecord, trustedLockHeld: Bool) throws {
        precondition(trustedLockHeld)
        let canonicalID = try canonicalJobID(record.jobID)
        try record.startReceipt?.validate(jobID: canonicalID)
        let directory = jobDirectory(forCanonicalID: canonicalID)
        var trustedRecord = record
        applyTrustedFileLayout(to: &trustedRecord, jobID: canonicalID, directory: directory)
        try createTrustedDirectoryChain(to: directory)
        let data = try encoder.encode(trustedRecord)
        try writeDurably(data, to: trustedMetadataURL(forCanonicalID: canonicalID))
        // This copy is a provider-visible projection only. It is useful to the
        // wrapper and operators, but never participates in admission or cleanup.
        // Its failure cannot roll back or contradict already-durable authority.
        let projectionURL = WorkspaceManagedJobFileLayout(directory: directory).metadata
        do {
            try beforeProviderProjectionWriteForTesting?(projectionURL)
            try data.write(to: projectionURL, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data("ASTRA managed-job metadata projection failed.\n".utf8))
        }
    }

    public func load(jobID: String) throws -> WorkspaceManagedJobRecord {
        let canonicalID = try canonicalJobID(jobID)
        let directory = jobDirectory(forCanonicalID: canonicalID)
        let metadataURL = trustedMetadataURL(forCanonicalID: canonicalID)
        if pathExistsWithoutFollowingSymlink(at: metadataURL) == false {
            throw jobNotFoundError(jobID: canonicalID)
        }
        guard trustedDirectoryStat(at: directory) != nil,
              isTrustedDirectoryChain(from: rootURL, to: directory) else {
            throw trustedFileReadError(path: directory.path)
        }
        guard let data = trustedStateFileData(at: metadataURL) else {
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

    /// Enumerates records through the same no-symlink/no-hardlink boundary as
    /// direct lookup. Any malformed candidate fails the whole listing so
    /// destructive cleanup preserves the executor.
    public func listTrustedRecords() throws -> [WorkspaceManagedJobRecord] {
        try withInvocationAdmissionLock {
            try listTrustedRecordsUnlocked()
        }
    }

    func withExclusiveAdmissionAndCleanup<T>(_ body: () throws -> T) throws -> T {
        try withInvocationAdmissionLock(body)
    }

    func listTrustedRecordsAssumingExclusiveAdmission() throws -> [WorkspaceManagedJobRecord] {
        try listTrustedRecordsUnlocked()
    }

    /// Fences a queued receipt before its detached effect. A retry may observe
    /// `.launching`, but must never repeat an ambiguously accepted launch.
    func launchQueuedInvocation(
        jobID: String,
        _ launch: (WorkspaceManagedJobRecord) throws -> WorkspaceManagedJobRecord
    ) throws -> WorkspaceManagedJobRecord {
        try withInvocationAdmissionLock {
            let canonicalID = try canonicalJobID(jobID)
            guard let record = try listTrustedRecordsUnlocked().first(where: { $0.jobID == canonicalID }) else {
                throw jobNotFoundError(jobID: canonicalID)
            }
            guard record.status == .queued else { return record }
            var fenced = record
            fenced.status = .launching
            fenced.updatedAt = Date()
            fenced.message = "Detached launch outcome is awaiting durable reconciliation."
            try save(fenced, trustedLockHeld: true)
            let launched = try launch(fenced)
            try afterLaunchBeforeSaveForTesting?()
            try save(launched, trustedLockHeld: true)
            return launched
        }
    }

    private func listTrustedRecordsUnlocked() throws -> [WorkspaceManagedJobRecord] {
        switch pathExistsWithoutFollowingSymlink(at: trustedStateRootURL) {
        case false:
            return []
        case nil:
            throw trustedFileReadError(path: trustedStateRootURL.path)
        case true:
            guard trustedDirectoryStat(at: trustedStateRootURL) != nil else {
                throw trustedFileReadError(path: trustedStateRootURL.path)
            }
        }

        let entries = try fileManager.contentsOfDirectory(
            at: trustedStateRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [WorkspaceManagedJobRecord] = []
        var ownerInvocations: Set<String> = []
        for entry in entries where entry.pathExtension == "json" {
            let name = entry.deletingPathExtension().lastPathComponent
            guard (try? canonicalJobID(name)) == name,
                  let data = trustedStateFileData(at: entry) else {
                throw trustedFileReadError(path: entry.path)
            }
            var record = try decoder.decode(WorkspaceManagedJobRecord.self, from: data)
            guard (try? canonicalJobID(record.jobID)) == name else {
                throw trustedFileReadError(path: entry.path)
            }
            try record.startReceipt?.validate(jobID: name)
            applyTrustedFileLayout(to: &record, jobID: name, directory: jobDirectory(forCanonicalID: name))
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

    private func withInvocationAdmissionLock<T>(_ body: () throws -> T) throws -> T {
        workspaceManagedJobAdmissionProcessLock.lock()
        defer { workspaceManagedJobAdmissionProcessLock.unlock() }
        try createTrustedStateDirectory()
        let lockURL = trustedStateRootURL.appendingPathComponent(".invocation-admission.lock", isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw trustedFileReadError(path: lockURL.path)
        }
        defer { close(descriptor) }

        var lockStat = stat()
        guard fstat(descriptor, &lockStat) == 0,
              (lockStat.st_mode & S_IFMT) == S_IFREG,
              lockStat.st_nlink == 1,
              flock(descriptor, LOCK_EX) == 0 else {
            throw trustedFileReadError(path: lockURL.path)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func trustedMetadataURL(forCanonicalID jobID: String) -> URL {
        trustedStateRootURL.appendingPathComponent(jobID + ".json", isDirectory: false)
    }

    private func createTrustedStateDirectory() throws {
        try validateTrustedCreationPath(to: trustedStateRootURL)
        try fileManager.createDirectory(at: trustedStateRootURL, withIntermediateDirectories: true)
        try validateTrustedCreationPath(to: trustedStateRootURL)
        guard trustedDirectoryStat(at: trustedStateRootURL) != nil else {
            throw trustedFileReadError(path: trustedStateRootURL.path)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trustedStateRootURL.path)
    }

    private func trustedStateFileData(at url: URL) -> Data? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path == trustedStateRootURL.standardizedFileURL.path else { return nil }
        return withTrustedFileDescriptor(at: url, inside: trustedStateRootURL) { fd in
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { result.append(buffer, count: count) }
                else if count == 0 { return result }
                else if errno != EINTR { return nil }
            }
        }
    }

    private func writeDurably(_ data: Data, to destination: URL) throws {
        try createTrustedStateDirectory()
        let temporary = trustedStateRootURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw trustedFileReadError(path: temporary.path) }
        var failure: Error?
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if count > 0 { offset += count }
                else if errno != EINTR {
                    failure = trustedFileReadError(path: temporary.path)
                    break
                }
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = trustedFileReadError(path: temporary.path) }
        _ = close(fd)
        if let failure {
            try? fileManager.removeItem(at: temporary)
            throw failure
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw trustedFileReadError(path: destination.path)
        }
        let directoryFD = open(trustedStateRootURL.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard directoryFD >= 0 else { throw trustedFileReadError(path: trustedStateRootURL.path) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw trustedFileReadError(path: trustedStateRootURL.path) }
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
        let containmentRoot = directory.standardizedFileURL.path == trustedStateRootURL.standardizedFileURL.path
            ? trustedStateRootURL
            : rootURL
        let rootPath = containmentRoot.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        guard (directoryPath == rootPath || WorkspaceManagedJobPathContainment.isDescendant(directoryPath, of: rootPath)),
              parentPath == directoryPath,
              isTrustedDirectoryChain(from: containmentRoot, to: directory) else {
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
        if status != .queued && status != .launching && status != .running {
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
            if record.status == .queued || record.status == .launching {
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
        self.store = WorkspaceManagedJobStore(
            rootPath: configuration.jobRootHostPath,
            trustedStateRootPath: configuration.managedJobTrustedStateHostPath
        )
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
        guard !providerCanWriteTrustedState else {
            return failedSynthetic(
                command: command,
                message: "Managed-job trusted state must be outside every provider-writable Docker mount."
            )
        }
        let pathResolution = configuration.containerCommand(for: trimmed)
        if let errorMessage = pathResolution.errorMessage {
            return failedSynthetic(command: command, message: errorMessage)
        }
        let admission: WorkspaceManagedJobAdmission
        do {
            _ = try WorkspaceManagedJobStartReceipt.make(
                taskID: configuration.taskID,
                runID: configuration.runID,
                invocationID: invocationID,
                requestFingerprint: try WorkspaceManagedJobRequestFingerprint.make(
                    command: pathResolution.command,
                    timeoutSeconds: timeoutSeconds,
                    label: label,
                    progressProbe: progressProbe
                ),
                containerName: configuration.containerName,
                jobID: "preflight"
            )
            admission = try store.admitInvocation(
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
        } catch {
            return failedSynthetic(command: command, message: error.localizedDescription)
        }
        do {
            let launched = try store.launchQueuedInvocation(jobID: admission.record.jobID) { queued in
                var record = queued
                let container = executor.ensureContainerStarted()
                guard container.exitCode == 0 else {
                    record.status = .failed
                    record.updatedAt = Date()
                    record.completedAt = record.updatedAt
                    record.message = container.stderr.isEmpty
                        ? "Failed to start Docker workspace container"
                        : container.stderr
                    record.exitCode = container.exitCode
                    return record
                }
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
                    record.status = .failed
                    record.updatedAt = Date()
                    record.completedAt = record.updatedAt
                    record.message = result.stderr.isEmpty
                        ? "Docker could not start the managed workspace job."
                        : result.stderr
                    record.exitCode = result.exitCode
                    return record
                }
                record.status = .running
                record.startedAt = Date()
                record.updatedAt = record.startedAt ?? record.updatedAt
                return record
            }
            return try store.load(jobID: launched.jobID)
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
            let directory = containerJobDirectory(jobID: record.jobID)
            _ = executor.runDockerCommand(
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
        guard !providerCanWriteTrustedState else { return true }
        do {
            return try store.listTrustedRecords().contains { record in
                guard !record.isTerminal else { return false }
                guard record.startReceipt != nil else {
                    // A legacy nonterminal record cannot prove that cleanup is
                    // safe, so preserve the executor.
                    return true
                }
                // Any conflicting ownership inside this executor-scoped trusted
                // store is corruption, not evidence that stopping is safe.
                return true
            }
        } catch {
            // Cleanup is destructive. Preserve the container when trusted
            // records cannot prove it idle.
            return true
        }
    }

    @discardableResult
    public func cleanupExecutorIfIdle(_ cleanup: () -> Void) -> Bool {
        guard !providerCanWriteTrustedState else { return false }
        do {
            return try store.withExclusiveAdmissionAndCleanup {
                guard !hasTrustedNonterminalOwnedJobUnlocked() else { return false }
                cleanup()
                return true
            }
        } catch {
            return false
        }
    }

    private func hasTrustedNonterminalOwnedJobUnlocked() -> Bool {
        do {
            return try store.listTrustedRecordsAssumingExclusiveAdmission().contains { record in
                guard !record.isTerminal else { return false }
                // A receipt mismatch is uncertain ownership and therefore also
                // preserves the executor.
                return true
            }
        } catch {
            return true
        }
    }

    private var providerCanWriteTrustedState: Bool {
        let trustedPath = URL(fileURLWithPath: configuration.managedJobTrustedStateHostPath)
            .standardizedFileURL.path
        return configuration.mounts.contains { mount in
            guard mount.access.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "ro" else {
                return false
            }
            let mountPath = URL(fileURLWithPath: mount.hostPath).standardizedFileURL.path
            return trustedPath == mountPath || WorkspaceManagedJobPathContainment.isDescendant(trustedPath, of: mountPath)
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
