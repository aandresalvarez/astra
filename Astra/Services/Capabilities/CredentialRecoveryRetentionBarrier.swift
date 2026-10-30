import Darwin
import Foundation
import ASTRAPersistence

/// A protocol fence in the shared account and workspace-deletion outboxes.
/// Pre-v2 readers cannot decode this as a deletion, so their existing
/// fail-closed scans block credential collection (and leave it untouched).
/// Current readers recognize only these exact bytes; the journal, not this
/// marker, owns the retained references. Never remove it while recovery debt
/// exists, even when the selected store changes.
enum CredentialRecoveryRetentionBarrier {
    static let filename = "account-credential-recovery-v2.json"
    private static let contents = Data("{\"kind\":\"account_credential_recovery_retention\",\"version\":2}".utf8)

    static func validate(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              try handle.read(upToCount: contents.count + 1) == contents
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// Confirm the fence is durable before publishing references that require
    /// v2 collectors. Failure leaves the original journal authoritative.
    static func install(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw CocoaError(.fileWriteNoPermission) }
        let url = directory.appendingPathComponent(filename)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            try validate(at: url)
        } catch where WorkspaceFileLayout.isMissingFile(error) {
            try contents.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try validate(at: url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let parent = open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw CocoaError(.fileWriteUnknown) }
        // The outbox itself may have been created by this operation. Its
        // entry in the shared root must survive before the receipt cutover.
        let root = open(directory.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(root) }
        guard fsync(root) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
