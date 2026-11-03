import Darwin
import Foundation

/// Per-task file operations keep fault injection scoped to one export and its
/// child tasks. Production always uses SQLite backup and atomic rename; tests
/// can reproduce partial writes and ENOSPC without exhausting a shared volume.
enum WorkspaceExportFileIO {
    @TaskLocal static var copySnapshot: @Sendable (URL, URL) throws -> Void = { source, destination in
        try WorkspaceRecoveryService.copyStoreSnapshot(from: source, to: destination)
    }

    @TaskLocal static var writeStaging: @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url)
    }

    @TaskLocal static var replace: @Sendable (URL, URL) throws -> Void = { staging, destination in
        guard Darwin.rename(staging.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
