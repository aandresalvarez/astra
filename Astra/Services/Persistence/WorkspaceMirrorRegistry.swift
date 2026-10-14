import CryptoKit
import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The workspace folders ASTRA has written a recovery mirror into, kept
/// outside the store so a store that is lost or rebuilt still knows them.
/// Startup recovery probes each one besides the Workspaces roots it scans: a
/// workspace imported from anywhere else would otherwise be found by no scan,
/// and cleanup trusting that recovery could remove what it still uses.
/// One record per folder, keyed by its path, so concurrent registrations
/// never rewrite each other.
public struct WorkspaceMirrorRegistry: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// The registry for the SwiftData store `modelContext` writes to: ASTRA's
    /// own store, inside its Application Support folder, shares one there, so
    /// a recovery that moves the store keeps it; any other on-disk store keeps
    /// one beside it. Nil for a store kept only in memory, whose workspaces no
    /// later launch recovers.
    public init?(for modelContext: ModelContext) {
        guard let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly })
        else { return nil }
        self.init(directory: Self.directory(
            forStoreAt: configuration.url, applicationSupport: WorkspaceRecoveryService.applicationSupportDirectory
        ))
    }

    public static func directory(forStoreAt store: URL, applicationSupport: URL) -> URL {
        let support = applicationSupport.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = store.standardizedFileURL.resolvingSymlinksInPath().path
        let root = resolved.hasPrefix(support.path + "/") ? support : store.deletingLastPathComponent()
        return root.appendingPathComponent("WorkspaceMirrorFolders", isDirectory: true)
    }

    /// Records each folder not already recorded. A folder that can't be
    /// recorded is logged: until it is, recovery can't find its mirror
    /// outside the scanned roots.
    public func register(_ folders: [String]) {
        for folder in Set(folders.map(WorkspacePathPresentation.standardizedPath)) where !folder.isEmpty {
            let url = recordURL(for: folder)
            // One that can't be checked is written again, which is harmless.
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { continue }
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                try Data(folder.utf8).write(to: url, options: .atomic)
            } catch {
                AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                    "operation": "register_workspace_mirror", "reason": "registry_unwritable",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
    }

    /// Every recorded folder, or nil when the registry or a record can't be
    /// read, since a folder it leaves out may hold the only mirror of an owner.
    public func folders() -> [String]? {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            return WorkspaceFileLayout.isMissingFile(error) ? [] : nil
        }
        var folders: [String] = []
        for url in urls where url.pathExtension == "folder" {
            guard let data = try? Data(contentsOf: url), let folder = String(data: data, encoding: .utf8), !folder.isEmpty
            else { return nil }
            folders.append(folder)
        }
        return folders.sorted()
    }

    private func recordURL(for folder: String) -> URL {
        let digest = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".folder")
    }
}
