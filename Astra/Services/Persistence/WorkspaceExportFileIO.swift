import Darwin
import Foundation

/// Per-task file operations keep fault injection scoped to one export and its
/// child tasks. Production always uses SQLite backup and atomic rename; tests
/// can reproduce partial writes and ENOSPC without exhausting a shared volume.
enum WorkspaceExportFileIO {
    // Scoped only around the synchronous low-level operation, not projection,
    // logging, or an await. Ordinary exports always use their existing URLs.
    @TaskLocal private static var cleanupDirectory: Int32?
    @TaskLocal static var copySnapshot: @Sendable (URL, URL) throws -> Void = { source, destination in
        try WorkspaceRecoveryService.copyStoreSnapshot(from: source, to: destination)
    }

    @TaskLocal static var writeStaging: @Sendable (Data, URL) throws -> Void = { data, url in
        guard let directory = cleanupDirectory else { try data.write(to: url); return }
        let descriptor = openat(directory, url.lastPathComponent,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o666)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    @TaskLocal static var replace: @Sendable (URL, URL) throws -> Void = { staging, destination in
        let result: Int32
        if let directory = cleanupDirectory {
            result = renameat(directory, staging.lastPathComponent, directory, destination.lastPathComponent)
        } else { result = Darwin.rename(staging.path, destination.path) }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func writeStagingFile(_ data: Data, to url: URL, directory: Int32?) throws {
        try $cleanupDirectory.withValue(directory) { try writeStaging(data, url) }
    }

    static func replaceStagedFile(_ staging: URL, at destination: URL, directory: Int32?) throws {
        try $cleanupDirectory.withValue(directory) { try replace(staging, destination) }
    }
}
