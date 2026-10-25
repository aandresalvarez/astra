import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// App-owned `<execution>/jobs/<job_id>.json`, one JSON file per job, each
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
            var initial = record
            initial.pendingTransitions = [RemoteWorkspaceJobTransition(record: record)]
            try write(initial, to: url)
        }
    }

    /// Serializes intent lookup/publication across helper processes. The
    /// journal reaches disk before SSH starts; reopens cannot create a new ID.
    public func register(_ record: RemoteWorkspaceJobRecord, prepareNew: (inout RemoteWorkspaceJobRecord) throws -> Void = { _ in }) throws -> (record: RemoteWorkspaceJobRecord, created: Bool) {
        try withLock(jobID: "00000000-0000-0000-0000-000000000000") {
            guard let intent = record.launchIntentKey else { throw RemoteWorkspaceJobStoreError.unreadable(rootURL.path) }
            if let existing = try records().first(where: { $0.launchIntentKey == intent }) {
                return (existing, false)
            }
            var admitted = record
            try prepareNew(&admitted)
            try create(admitted)
            return (admitted, true)
        }
    }

    public func records() throws -> [RemoteWorkspaceJobRecord] {
        var info = stat()
        if lstat(rootURL.path, &info) != 0 {
            guard errno == ENOENT else { throw RemoteWorkspaceJobStoreError.unreadable(rootURL.path) }
            return []
        }
        try prepareRoot()
        return try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try load(jobID: $0.deletingPathExtension().lastPathComponent) }
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
            let before = record
            try body(&record)
            if record.status != before.status || record.lastObservation?.outcome != before.lastObservation?.outcome
                || record.cancellationRequestedAt != before.cancellationRequestedAt {
                record.pendingTransitions = (record.pendingTransitions ?? []) + [RemoteWorkspaceJobTransition(record: record, cancellation: record.cancellationRequestedAt != before.cancellationRequestedAt)]
            }
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
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0, info.st_size <= 1_048_576 else {
            throw RemoteWorkspaceJobStoreError.unreadable(url.path)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let record = try? decoder.decode(RemoteWorkspaceJobRecord.self, from: data),
              (try? Self.canonicalJobID(record.jobID)) == (try Self.canonicalJobID(jobID)) else {
            throw RemoteWorkspaceJobStoreError.unreadable(url.path)
        }
        return record
    }

    private func write(_ record: RemoteWorkspaceJobRecord, to url: URL) throws {
        let data = try encoder.encode(record)
        let temporary = rootURL.appendingPathComponent(UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteWorkspaceJobStoreError.unreadable(url.path) }
        defer { close(fd); unlink(temporary.path) }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw RemoteWorkspaceJobStoreError.unreadable(url.path)
        }
        let parent = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw RemoteWorkspaceJobStoreError.unreadable(url.path) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw RemoteWorkspaceJobStoreError.unreadable(url.path) }
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
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw RemoteWorkspaceJobStoreError.unsafePath(rootURL.path)
            }
            return
        }
        guard errno == ENOENT else { throw RemoteWorkspaceJobStoreError.unreadable(rootURL.path) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func withLock<T>(jobID: String, _ body: () throws -> T) throws -> T {
        try prepareRoot()
        let lockPath = rootURL.appendingPathComponent(".\(try Self.canonicalJobID(jobID)).lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteWorkspaceJobStoreError.unsafePath(lockPath) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw RemoteWorkspaceJobStoreError.unsafePath(lockPath) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw RemoteWorkspaceJobStoreError.unreadable(lockPath) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
