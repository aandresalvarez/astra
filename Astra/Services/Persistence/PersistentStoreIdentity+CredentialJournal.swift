import Darwin
import Foundation
import SwiftData

extension PersistentStoreIdentity {
    /// Credential journals outlive a mount session. st_dev (the historical
    /// `current` format) can change after a reboot; the volume UUID does not.
    /// Path, inode and birth time still distinguish a replacement or recovery.
    /// Other persisted contracts keep their existing identity format.
    public static func credentialJournal(for modelContext: ModelContext) -> String? {
        guard let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly })
        else { return current(for: modelContext) }
        return credentialJournal(forStoreAt: configuration.url)
    }

    public static func credentialJournal(forStoreAt url: URL) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var metadata = stat()
        guard lstat(resolved.path, &metadata) == 0 else { return nil }
        let volume = try? resolved.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return credentialJournal(forStoreAt: resolved, volumeUUID: volume, metadata: metadata)
    }

    static func credentialJournal(forStoreAt url: URL, volumeUUID: String?, metadata: stat) -> String? {
        guard let volumeUUID, let volume = UUID(uuidString: volumeUUID),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_ino > 0,
              metadata.st_birthtimespec.tv_sec > 0,
              (0..<1_000_000_000).contains(metadata.st_birthtimespec.tv_nsec) else { return nil }
        return url.path + "|credential-v2:\(volume.uuidString):\(metadata.st_ino):\(metadata.st_birthtimespec.tv_sec):\(metadata.st_birthtimespec.tv_nsec)"
    }
}
